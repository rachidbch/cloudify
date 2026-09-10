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
# Record text is opaque to this module: the schema belongs to the writer (T3).
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
