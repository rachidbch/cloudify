#!/usr/bin/env bash
# lib/registry.sh — registry storage (Branch 7 T2)
#
# The registry is OBSERVATION, not intent: one record per
# (deployment, target, package), stored on disk next to the target's own state.
# It is never a precedence source for the var ladder (I7-2) and never committed
# to git (I7-4; git is not a backup).
#
# Bucket (the storage root for a target):
#   node target     -> $(ivps node path <node>)
#   instance target -> $(ivps node path <node>)/<instance>
#   fallback        -> ${CLOUDIFY_CREDENTIALS_DIR:-$HOME/.config/cloudify}/registry/hosts/<ssh_host>
#                      (no node, ivps absent, or `ivps node path` fails — e.g.
#                      `local` until ivps exposes it). Never fails the caller.
#
# Record path inside a bucket: <bucket>/deployments/<id>/pkgs/<pkg>/config.yaml
# Perms: parent dir 0700, file 0600, enforced by the writer (I7-5).
# Writes are atomic: mktemp in the record's own dir + mv (I7-6); a concurrent
# write to the same slice is last-writer-wins (accepted).
#
# Record schema + writer (T3) are the last two sections below.
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_REGISTRY_LOADED:-}" ]] && return 0
_CLOUDIFY_REGISTRY_LOADED=1

#== Internals ==

# _cloudify_registry_fallback_root — plain-host bucket root (resolved at call
# time so tests/callers can repoint CLOUDIFY_CREDENTIALS_DIR after sourcing)
function _cloudify_registry_fallback_root() {
    printf '%s\n' "${CLOUDIFY_CREDENTIALS_DIR:-$HOME/.config/cloudify}/registry/hosts"
}

# _cloudify_registry_node_dir <node> — the ivps node dir, rc 1 when unknown
function _cloudify_registry_node_dir() {
    local node="${1:-}" dir
    [[ -n "$node" ]] || return 1
    command -v ivps >/dev/null 2>&1 || return 1
    dir=$(ivps node path "$node" 2>/dev/null) || return 1
    [[ -n "$dir" ]] || return 1
    printf '%s\n' "$dir"
}

# _cloudify_registry_check <label> <value> [required]
# Rejects path separators and dot components in every path component; optional
# components (node, instance, ssh_host) may be empty.
function _cloudify_registry_check() {
    local label="$1" value="$2" required="${3:-0}"
    if [[ -z "$value" ]]; then
        [[ "$required" == "1" ]] && die "Registry: $label is required."
        return 0
    fi
    if [[ "$value" == *"/"* || "$value" == "." || "$value" == ".." ]]; then
        die "Registry: invalid $label '$value' (no path separators)."
    fi
}

# _cloudify_registry_base <node> <instance> <ssh_host> — bucket dir.
# rc 1 (quiet) when the node dir is unresolvable AND there is no ssh host to
# key the fallback bucket with: such a target has no addressable storage.
function _cloudify_registry_base() {
    local node="${1:-}" instance="${2:-}" ssh_host="${3:-}" dir
    if dir=$(_cloudify_registry_node_dir "$node"); then
        [[ -n "$instance" ]] && dir="$dir/$instance"
        printf '%s\n' "$dir"
        return 0
    fi
    [[ -n "$ssh_host" ]] || return 1
    dir="$(_cloudify_registry_fallback_root)/$ssh_host"
    [[ -n "$instance" ]] && dir="$dir/$instance"
    printf '%s\n' "$dir"
}

#== Public API ==

# cloudify_registry_file <deployment> <node> <instance> <ssh_host> <pkg>
# Print the record path. Pure: no mkdir, no ivps mutation (a read-only
# `ivps node path` probe is the only call).
function cloudify_registry_file() {
    local deployment="${1:-}" node="${2:-}" instance="${3:-}" ssh_host="${4:-}" pkg="${5:-}" base
    _cloudify_registry_check "deployment" "$deployment" 1
    _cloudify_registry_check "pkg" "$pkg" 1
    _cloudify_registry_check "node" "$node"
    _cloudify_registry_check "instance" "$instance"
    _cloudify_registry_check "ssh host" "$ssh_host"
    base=$(_cloudify_registry_base "$node" "$instance" "$ssh_host") ||
        die "Registry: no storage bucket for target (node '$node' unresolved, no ssh host)."
    printf '%s/deployments/%s/pkgs/%s/config.yaml\n' "$base" "$deployment" "$pkg"
}

# cloudify_registry_put <deployment> <node> <instance> <ssh_host> <pkg>
# Record text on stdin. Creates the parent chain (0700), writes atomically.
function cloudify_registry_put() {
    local file dir tmp
    file=$(cloudify_registry_file "$@") || return 1
    dir="${file%/*}"
    # umask 077 so the whole freshly-created chain is 0700 (-m with -p would
    # only cover the deepest level); chmod pins the record's own parent even
    # when it already existed with looser perms (I7-5).
    (umask 077; mkdir -p "$dir")
    chmod 700 "$dir" 2>/dev/null || true
    tmp=$(mktemp "$dir/.config.yaml.XXXXXX") || return 1
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$file"
}

# cloudify_registry_get <deployment> <node> <instance> <ssh_host> <pkg>
# Print the record; rc 1 and no output when absent.
function cloudify_registry_get() {
    local file
    file=$(cloudify_registry_file "$@") || return 1
    [[ -f "$file" ]] || return 1
    cat "$file"
}

# cloudify_registry_delete <deployment> <node> <instance> <ssh_host> <pkg>
# Remove the record and prune now-empty parents up to (never including) the
# deployment dir, i.e. <pkg>/ then pkgs/; `deployments/<id>` is left to T4 and
# the bucket root is ivps-owned. rc 0 when the record is absent.
function cloudify_registry_delete() {
    local file pkg_dir pkgs_dir
    file=$(cloudify_registry_file "$@") || return 1
    if [[ -e "$file" ]]; then
        trash-put "$file" 2>/dev/null || rm -f "$file"
    fi
    pkg_dir="${file%/*}"
    pkgs_dir="${pkg_dir%/*}"
    rmdir "$pkg_dir" 2>/dev/null || true
    rmdir "$pkgs_dir" 2>/dev/null || true
    return 0
}

# cloudify_registry_list <deployment> <node> <instance> [ssh_host]
# Print the packages holding a record for that target, one per line.
# ssh_host is only needed when the node dir is unresolvable (fallback bucket);
# an unaddressable bucket lists nothing (rc 0).
function cloudify_registry_list() {
    local deployment="${1:-}" node="${2:-}" instance="${3:-}" ssh_host="${4:-}" base pkgs_dir dir
    _cloudify_registry_check "deployment" "$deployment" 1
    _cloudify_registry_check "node" "$node"
    _cloudify_registry_check "instance" "$instance"
    _cloudify_registry_check "ssh host" "$ssh_host"
    base=$(_cloudify_registry_base "$node" "$instance" "$ssh_host") || return 0
    pkgs_dir="$base/deployments/$deployment/pkgs"
    [[ -d "$pkgs_dir" ]] || return 0
    for dir in "$pkgs_dir"/*/; do
        [[ -f "${dir}config.yaml" ]] || continue
        printf '%s\n' "$(basename "${dir%/}")"
    done
    return 0
}

# _cloudify_registry_delete_record_tree <dir> — trash a record dir.
# Only a dir holding a `pkgs/` subdir is a registry record dir: the guard keeps a
# sweep away from an unrelated same-named directory. rc 1 (no side effect) when
# the dir is absent or not a record dir.
function _cloudify_registry_delete_record_tree() {
    local dir="${1:-}"
    [[ -d "$dir/pkgs" ]] || return 1
    if trash-put "$dir" 2>/dev/null; then
        log_info "Registry: removed record dir $dir"
    else
        rm -rf "$dir"
        log_warn "Registry: trash-put unavailable, removed $dir directly."
    fi
}

# cloudify_registry_delete_deployment <deployment>
# Remove every registry record dir for a deployment. Records live OUTSIDE the
# deployment store; the Phase 7 application teardown calls this once it removes
# the store (T4).
#
# Candidate bucket roots (globbed, never shelling out to ivps):
#   - every node dir under ${IVPS_CONFIG_DIR:-<xdg>/ivps}/nodes
#   - every host dir under ${CLOUDIFY_CREDENTIALS_DIR:-$HOME/.config/cloudify}/registry/hosts
# In each root both target layouts are checked:
#   node target      <root>/deployments/<id>
#   instance target  <root>/<instance>/deployments/<id>
# Only dirs holding a `pkgs/` subdir are removed. rc 0 when nothing matches.
# A record dir emptied by cloudify_registry_delete (no `pkgs/` left) is left in
# place: without the guard the sole safety net is the name, which is not enough.
function cloudify_registry_delete_deployment() {
    local deployment="${1:-}"
    _cloudify_registry_check "deployment" "$deployment" 1
    local base root target
    for base in \
        "${IVPS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ivps}/nodes" \
        "$(_cloudify_registry_fallback_root)"; do
        [[ -d "$base" ]] || continue
        for root in "$base"/*/; do
            [[ -d "$root" ]] || continue
            root="${root%/}"
            for target in "$root/deployments/$deployment" "$root"/*/deployments/"$deployment"; do
                _cloudify_registry_delete_record_tree "$target" || continue
            done
        done
    done
    return 0
}

#== Record schema + writer (T3) ==
#
# A record is a flat `key: value` file (house style), first line a comment,
# stable field order. The writer MERGES with any existing record so earlier
# timestamps survive: the registry is observation, so an uninstall is a
# timestamp (`removed_at`), never a delete.
#
# `var.<NAME>` holds the RAW value from the first providing source
# (env > deployment store > package store > global store) at write time, so a
# stored `@backend:...` reference stays a reference (I7-4). Names come from
# pkg/<pkg>/.remote-vars; a name no source provides is skipped. A value that
# cannot live on one line is stored as `@base64:` (the var-store encoding).
# `version` has no source yet and stays empty.
#
# The value source is the dispatch context, so the record and the payload are
# one resolution. A context-free direct call (a red proof, a diagnostic) builds
# its own context through the SAME resolver, never a second value walk.

# _cloudify_registry_now — UTC ISO8601, second precision
function _cloudify_registry_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# _cloudify_registry_field <key> <value> — `key: value`, or `key:` when empty
function _cloudify_registry_field() {
    if [[ -n "$2" ]]; then printf '%s: %s\n' "$1" "$2"; else printf '%s:\n' "$1"; fi
}

# _cloudify_registry_declared_names <pkg> — declared names, declaration order
function _cloudify_registry_declared_names() {
    local pkg="${1:-}" decl line name
    [[ -n "$pkg" && -n "${CLOUDIFY_DIR:-}" ]] || return 0
    decl="$CLOUDIFY_DIR/pkg/$pkg/.remote-vars"
    [[ -f "$decl" ]] || return 0
    while IFS= read -r line; do
        line="$(_cloudify_vars_trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)$ ]]; then
            name="${BASH_REMATCH[1]}"
        else
            continue
        fi
        printf '%s\n' "$name"
    done < "$decl"
}

# _cloudify_registry_context_raw <context-file> <name>
# The raw, unresolved value for <name> as the dispatch resolution recorded it.
# The context carries it as `t:<text>` or `b:<base64>`; see
# _cloudify_vars_sources_record for why the form is explicit. rc 1 when the
# context has no block for the name, i.e. no source provided it.
#
# This deliberately does NOT reopen a source. The value was resolved once, during
# the dispatch, and the raw text was recorded at that same moment; reading a
# store again here would let the record drift from what the payload forwarded,
# and would make a deliberately empty value indistinguishable from an absent one.
function _cloudify_registry_context_raw() {
    local context="$1" name="$2" enc
    enc=$(cloudify_context_read "$context" "value.$name.raw") || return 1
    [[ -n "$enc" ]] || return 1
    _cloudify_vars_raw_decode "$enc"
}

# cloudify_registry_record_build <action> <deployment> <node> <instance> <ssh_host> <pkg> [context-file]
# Print the merged record on stdout. Reads the existing record (if any) to
# carry timestamps + version over; writes nothing.
#
# `var.<NAME>` values come from the dispatch context (the router's per-pid
# `_CLOUDIFY_BG_CONTEXT`, read through cloudify_context_read, or the one given
# here), so the record's source and the payload's source are one resolution.
# A context-free direct call builds its own context through the SAME resolver:
# never a second value walk. Value and field order are unchanged: the names
# still come from pkg/<pkg>/.remote-vars in declaration order, and the value is
# still the raw, unresolved form (inv 18).
function cloudify_registry_record_build() {
    local action="${1:-}" deployment="${2:-}" node="${3:-}" instance="${4:-}" ssh_host="${5:-}" pkg="${6:-}" context="${7:-}"
    local own_context=""
    if [[ -z "$context" ]]; then
        own_context=$(mktemp "$CLOUDIFY_TMP/cloudify-registry-context-XXXXXX") \
            || die "Registry: cannot create a context file under $CLOUDIFY_TMP."
        chmod 600 "$own_context"
        trap '[[ "${FUNCNAME[0]:-}" == "cloudify_registry_record_build" ]] && rm -f "${own_context:-}"' RETURN
        local cand_file
        cand_file=$(mktemp) || die "Registry: cannot create a candidate name file."
        local _dname
        while IFS= read -r _dname; do
            [[ -n "$_dname" ]] && printf '%s\t%s\trequired\n' "$_dname" "$pkg" >> "$cand_file"
        done < <(_cloudify_registry_declared_names "$pkg")
        # Env-prefix form (house style): the resolver reads the path from the
        # environment for this one command, so the caller's own
        # CLOUDIFY_CONTEXT_FILE is never clobbered.
        CLOUDIFY_CONTEXT_FILE="$own_context" \
            cloudify_context_build install "$deployment" install "$cand_file" "$pkg" > /dev/null
        rm -f "$cand_file"
        context="$own_context"
    fi
    local status installed_at configured_at removed_at
    local -A existing=()
    local text line key value name raw
    text=$(cloudify_registry_get "$deployment" "$node" "$instance" "$ssh_host" "$pkg" 2>/dev/null) || true
    while IFS= read -r line; do
        [[ "$line" == *:* && "$line" != \#* ]] || continue
        key="$(_cloudify_vars_trim "${line%%:*}")"
        [[ -n "$key" ]] || continue
        value="$(_cloudify_vars_trim "${line#*:}")"
        existing["$key"]="$value"
    done <<< "$text"

    installed_at="${existing[installed_at]:-}"
    configured_at="${existing[configured_at]:-}"
    removed_at="${existing[removed_at]:-}"
    case "$action" in
        install) status=installed; installed_at="$(_cloudify_registry_now)" ;;
        configure) status=configured; configured_at="$(_cloudify_registry_now)" ;;
        uninstall) status=removed; removed_at="$(_cloudify_registry_now)" ;;
        *) die "Registry: unknown action '${action:-}' (expected install, configure or uninstall)." ;;
    esac

    printf '%s\n' '# cloudify registry record (observation); do not edit by hand'
    _cloudify_registry_field status "$status"
    _cloudify_registry_field installed_at "$installed_at"
    _cloudify_registry_field configured_at "$configured_at"
    _cloudify_registry_field removed_at "$removed_at"
    _cloudify_registry_field deployment "$deployment"
    _cloudify_registry_field node "$node"
    _cloudify_registry_field instance "$instance"
    _cloudify_registry_field package "$pkg"
    _cloudify_registry_field version "${existing[version]:-}"

    # Value source: the context, always. A name with no context block is
    # skipped: no source provided it.
    local -A seen=()
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        [[ -n "${seen[$name]:-}" ]] && continue
        seen["$name"]=1
        # The raw text the resolution recorded, not a second look at a store.
        # The context's transport form is decoded, then re-encoded into the
        # record's own convention below, so the record's bytes are unchanged.
        raw=$(_cloudify_registry_context_raw "$context" "$name") || continue
        if [[ "$(cloudify_context_read "$context" "value.$name.secret" 2>/dev/null || true)" == "true" ]]; then
            PKG_DEBUG "Registry: var.$name is marked secret; the record keeps its raw, unresolved form."
        fi
        if [[ "$raw" == *$'\n'* ]]; then
            raw="@base64:$(printf '%s' "$raw" | base64 -w0)"
        fi
        _cloudify_registry_field "var.$name" "$raw"
    done < <(_cloudify_registry_declared_names "$pkg")
}

# cloudify_registry_record_apply <action> <deployment> <node> <instance> <ssh_host> <pkg> [context-file]
# Build the record and write it with cloudify_registry_put (atomic, 0700/0600).
# The optional context path is for the builder only; the bucket key is the five
# target fields (cloudify_registry_put takes no context).
function cloudify_registry_record_apply() {
    local action="$1"
    shift
    local -a args=("$@")
    cloudify_registry_record_build "$action" "${args[@]}" |
        cloudify_registry_put "${args[@]:0:5}"
}

# _cloudify_registry_record_bg <pid> — write records for one finished dispatch.
# Reads the router's pid-keyed metadata arrays `_CLOUDIFY_BG_ACTION`,
# `_CLOUDIFY_BG_PKGS`, `_CLOUDIFY_BG_TARGET` and `_CLOUDIFY_BG_CONTEXT`
# (dynamic scope from main()). Observation only: verify dispatches and an unset
# CLOUDIFY_DEPLOYMENT are skipped (I7-8), and a write failure warns — it never
# aborts the run.
#
# The record's values come from the dispatch's context file, so a dispatch whose
# context is missing or unreadable writes NO record and warns: never a second
# walk (design section 5).
function _cloudify_registry_record_bg() {
    local pid="$1"
    local action="${_CLOUDIFY_BG_ACTION[$pid]:-}"
    case "$action" in
        install | configure | uninstall) ;;
        *) return 0 ;;
    esac
    if [[ -z "${CLOUDIFY_DEPLOYMENT:-}" ]]; then
        PKG_DEBUG "Registry: CLOUDIFY_DEPLOYMENT is unset - no record for '${_CLOUDIFY_BG_PKGS[$pid]:-}'."
        return 0
    fi
    local context="${_CLOUDIFY_BG_CONTEXT[$pid]:-}"
    if [[ -z "$context" || ! -r "$context" ]]; then
        log_warn "Registry: dispatch context '${context:-<unset>}' is missing or unreadable - no record written for '${_CLOUDIFY_BG_PKGS[$pid]:-}' (never a second value walk)."
        return 0
    fi
    local target="${_CLOUDIFY_BG_TARGET[$pid]:-}" node instance ssh_host rest pkg
    node="${target%%$'\t'*}"
    rest="${target#*$'\t'}"
    instance="${rest%%$'\t'*}"
    ssh_host="${rest#*$'\t'}"
    for pkg in ${_CLOUDIFY_BG_PKGS[$pid]:-}; do
        [[ -n "$pkg" ]] || continue
        if ! ( cloudify_registry_record_apply "$action" "$CLOUDIFY_DEPLOYMENT" "$node" "$instance" "$ssh_host" "$pkg" "$context" ); then
            log_warn "Registry: no record written for '$pkg' on target '${ssh_host:-unaddressable}'."
        fi
    done
    # The parent owns the context file: remove it after the write (design
    # section 5). A missing/unreadable file warns above and is left alone.
    if [[ -n "$context" && -e "$context" ]]; then
        rm -f "$context"
    fi
    return 0
}
