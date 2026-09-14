#!/usr/bin/env bash
# lib/targets.sh — `--on` target grammar: node / instance / plain host
# Operator-side and validation-only: resolving a target never provisions.
# Grammar (each token must exist; the syntax asserts the kind):
#   X    -> kind discovered; X both a node and an instance = error (fail closed)
#   X:   -> X must be an ivps node
#   X:Y  -> X must be an ivps node, Y an instance on X
#   :Y   -> Y an instance on the active node (CLOUDIFY_NODE), else the ivps
#           default (IVPS_DEFAULT_NODE), else error
# No localhost fallback: `local`/`localhost` is an ivps node like any other.
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_TARGETS_LOADED:-}" ]] && return 0
_CLOUDIFY_TARGETS_LOADED=1

#== ivps inventory probes (thin wrappers so tests can stub `ivps`) ==

# _cloudify_target_ivps_config — path to the ivps config file
function _cloudify_target_ivps_config() {
    echo "${IVPS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ivps}/config.env"
}

# _cloudify_target_node_exists <node> — rc 0 when ivps knows the node
function _cloudify_target_node_exists() {
    local node="${1:-}"
    [[ -n "$node" ]] || return 1
    command -v ivps >/dev/null 2>&1 || return 1
    ivps node path "$node" >/dev/null 2>&1
}

# _cloudify_target_ivps_list [refresh] — the `ivps list` inventory table, fetched
# once per process and cached. Each fetch probes every remote live (a 5s cap per
# node), so it is expensive; `refresh` discards the cache and probes again.
# rc 1 when ivps is unavailable or the list fails.
function _cloudify_target_ivps_list() {
    if [[ "${1:-}" == refresh || -z "${_CLOUDIFY_TARGET_INV_READY:-}" ]]; then
        _CLOUDIFY_TARGET_INV_READY=1
        _CLOUDIFY_TARGET_INV_RC=1
        if command -v ivps >/dev/null 2>&1 && _CLOUDIFY_TARGET_INV=$(ivps list 2>/dev/null); then
            _CLOUDIFY_TARGET_INV_RC=0
        else
            _CLOUDIFY_TARGET_INV=""
        fi
    fi
    [[ -n "${_CLOUDIFY_TARGET_INV:-}" ]] && printf '%s\n' "$_CLOUDIFY_TARGET_INV"
    return "${_CLOUDIFY_TARGET_INV_RC:-1}"
}

# _cloudify_target_timed_out_nodes — the nodes whose `ivps list` probe timed out,
# one per line. `ivps list` renders such a node as a bare "<node>  TIMEOUT" row
# (no colon), so a timed-out node's instances are absent from the table: this is
# the signal that the table is incomplete.
function _cloudify_target_timed_out_nodes() {
    local listed
    listed=$(_cloudify_target_ivps_list) || return 0
    awk '$1 !~ /:/ && $2 == "TIMEOUT" { print $1 }' <<< "$listed"
}

# _cloudify_target_node_timed_out <node> — rc 0 when <node> answered `ivps list`
# with a TIMEOUT row (it is known from ivps metadata but was unobservable).
function _cloudify_target_node_timed_out() {
    local node="${1:-}"
    [[ -n "$node" ]] || return 1
    _cloudify_target_timed_out_nodes | grep -qxF "$node"
}

# _cloudify_target_inventory_settle — fetch the inventory, and when a node timed
# out (usually transient) probe once more before accepting the table. Cached for
# the rest of the process, so this is one probe normally and two on a timeout.
function _cloudify_target_inventory_settle() {
    _cloudify_target_ivps_list >/dev/null || return 0
    if [[ -n "$(_cloudify_target_timed_out_nodes)" ]]; then
        _cloudify_target_ivps_list refresh >/dev/null || true
    fi
    return 0
}

# _cloudify_target_instance_nodes <instance> — print the node(s) hosting <instance>
# `ivps list` rows are "<node>:<name>" (e.g. "cloudai:cloudify"); a local instance
# is rendered as "local:<name>". rc 1 when ivps is unavailable. A node that timed
# out contributes no rows, so its instances are invisible here: callers must use
# _cloudify_target_node_timed_out/_cloudify_target_timed_out_nodes to tell
# "absent" from "unobservable".
function _cloudify_target_instance_nodes() {
    local instance="${1:-}"
    [[ -n "$instance" ]] || return 1
    local listed
    listed=$(_cloudify_target_ivps_list) || return 1
    awk -v want="$instance" '
        $1 ~ /^[^:]+:.+$/ {
            split($1, a, ":")
            if (a[2] == want) print a[1]
        }' <<< "$listed" | sort -u
}

# _cloudify_target_node_ssh_host <node> — ssh name for a node target
function _cloudify_target_node_ssh_host() {
    [[ "${1:-}" == "local" ]] && echo localhost || echo "${1:-}"
}

#== Public helpers ==

# _cloudify_target_active_node — per-shell active node (CLOUDIFY_NODE), else empty
function _cloudify_target_active_node() {
    printf '%s\n' "${CLOUDIFY_NODE:-}"
}

# _cloudify_target_default_node — ivps IVPS_DEFAULT_NODE, else empty
function _cloudify_target_default_node() {
    local config val=""
    config=$(_cloudify_target_ivps_config)
    if [[ -f "$config" ]]; then
        val=$(awk -F= '/^[[:space:]]*IVPS_DEFAULT_NODE=/{v=$2; gsub(/["\047]/,"",v); sub(/[[:space:]]+$/,"",v); print v}' "$config" | tail -1)
    fi
    [[ -n "$val" ]] || val="${IVPS_DEFAULT_NODE:-}"
    printf '%s\n' "$val"
}

# _cloudify_target_resolve <token> — print "<node>\t<instance>\t<ssh_host>"
# Empty fields are allowed (a plain host has no node/instance). ssh_host is the
# instance name for an instance target, the node name for a node target, and
# `localhost` for node `local`. Validation dies here (fail closed).
function _cloudify_target_resolve() {
    local token="${1:-}"
    [[ -n "$token" ]] || die "Cloudify usage error: empty target."

    # localhost is the local ivps node — a node like any other, not a fallback
    if [[ "$token" == "localhost" ]]; then
        printf 'local\t\tlocalhost\n'
        return 0
    fi

    # A lone colon is a usage error, not a host name
    [[ "$token" == ":" ]] && die "Target ':': missing node and instance."

    # Explicit forms. The pattern keeps an IPv6-looking token (which has several
    # colons, or non-name characters) on the bare-name path (ROADMAP: non-urgent).
    local node_part="" instance_part=""
    if [[ "$token" =~ ^([A-Za-z0-9_.-]+):([A-Za-z0-9_.-]*)$ ]]; then
        node_part="${BASH_REMATCH[1]}"
        instance_part="${BASH_REMATCH[2]}"
    elif [[ "$token" =~ ^:([A-Za-z0-9_.-]+)$ ]]; then
        node_part=""
        instance_part="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$node_part" || -n "$instance_part" ]]; then
        command -v ivps >/dev/null 2>&1 || die "Target '$token': ivps is required to resolve '<node>:' and '<node>:<instance>' targets but is not installed."
        # `localhost` names node `local`, consistently with the bare form
        [[ "$node_part" == "localhost" ]] && node_part=local

        local node="$node_part"
        if [[ -z "$node_part" ]]; then
            node=$(_cloudify_target_active_node)
            [[ -n "$node" ]] || node=$(_cloudify_target_default_node)
            [[ -n "$node" ]] || die "Target '$token': no active node. Set one with: eval \"\$(cloudify node use <node>)\" or export CLOUDIFY_NODE=<node>."
            _cloudify_target_node_exists "$node" || die "Target '$token': active node '$node' (CLOUDIFY_NODE/IVPS_DEFAULT_NODE) not found in the ivps inventory."
        else
            _cloudify_target_node_exists "$node" || die "Target '$token': node '$node' not found in the ivps inventory."
        fi

        # X: / localhost: — node target
        if [[ -z "$instance_part" ]]; then
            printf '%s\t\t%s\n' "$node" "$(_cloudify_target_node_ssh_host "$node")"
            return 0
        fi

        # X:Y / :Y — instance target. The instance is only visible when the node
        # answered the live probe; settle the inventory once, then a node that
        # timed out is a timeout, never a false "not on node".
        _cloudify_target_inventory_settle
        local inst_nodes=""
        inst_nodes=$(_cloudify_target_instance_nodes "$instance_part" || true)
        if ! grep -qxF "$node" <<< "$inst_nodes"; then
            if _cloudify_target_node_timed_out "$node"; then
                die "Target '$token': node '$node' did not answer the ivps inventory probe (timed out); '$instance_part' could not be confirmed. Retry when the node responds."
            fi
            die "Target '$token': instance '$instance_part' is not on node '$node'."
        fi
        printf '%s\t%s\t%s\n' "$node" "$instance_part" "$instance_part"
        return 0
    fi

    # Bare token: discover the kind (existence is always required)
    _cloudify_target_inventory_settle
    local is_node=false inst_nodes=""
    _cloudify_target_node_exists "$token" && is_node=true
    inst_nodes=$(_cloudify_target_instance_nodes "$token" || true)

    if $is_node && [[ -n "$inst_nodes" ]]; then
        die "Target '$token' is ambiguous: it is both an ivps node and an instance. Use '$token:' for the node or '<node>:$token' for the instance."
    fi
    if $is_node; then
        printf '%s\t\t%s\n' "$token" "$(_cloudify_target_node_ssh_host "$token")"
        return 0
    fi
    if [[ -n "$inst_nodes" ]]; then
        if [[ "$(wc -l <<< "$inst_nodes")" -gt 1 ]]; then
            die "Target '$token' is ambiguous: instance '$token' exists on several nodes ($(tr '\n' ' ' <<< "$inst_nodes")). Use '<node>:$token'."
        fi
        printf '%s\t%s\t%s\n' "$inst_nodes" "$token" "$token"
        return 0
    fi

    # Not a node, not a found instance. If a node timed out the inventory is
    # incomplete, so "not found" is not conclusive: refuse rather than record a
    # silently wrong external host.
    local timed_out
    timed_out=$(_cloudify_target_timed_out_nodes)
    if [[ -n "$timed_out" ]]; then
        die "Target '$token': not found in the ivps inventory, and node(s) $(tr '\n' ' ' <<< "$timed_out")did not answer the inventory probe (timed out); '$token' may be an instance on one of them. Retry, or address it as <node>:$token."
    fi

    # Plain host (back-compat): not in the ivps inventory, ssh validates reachability
    printf '\t\t%s\n' "$token"
}

# cloudify_node_use <node> — print the export command (can't set the parent shell env)
function cloudify_node_use() {
    local node="${1:-}"
    [[ -n "$node" ]] || die "Node name is required"
    [[ "$node" == "localhost" ]] && node=local
    command -v ivps >/dev/null 2>&1 || die "ivps is not installed. Cannot resolve node '$node'."
    _cloudify_target_node_exists "$node" || die "Node '$node' not found in the ivps inventory. List nodes with: ivps node list"
    echo "export CLOUDIFY_NODE=$node"
    echo "# Run: eval \"\$(cloudify node use $node)\""
}
