#!/usr/bin/env bash
# lib/state.sh - the Cloudify state root and the deployment manifest (Phase 3).
#
# Two things live here, and nothing else:
#   1. the ONE state-root helper (REDESIGN "Data homes"):
#      ${XDG_STATE_HOME:-$HOME/.local/state}/cloudify. Desired inputs and
#      defaults stay under the existing Cloudify configuration helper
#      (lib/vars.sh:cloudify_vars_config_dir); current state routes here.
#      The manifest uses it today; the Phase 4/6 runs, events and external-host
#      state get their path helpers here now so no later phase invents a root.
#   2. the deployment manifest: one local flock per manifest, atomic creation
#      before the first mutating step, and the fields of
#      schemas/v1/deployment-manifest.schema.json exactly (schema_version 1).
#      Identity, application commit, deployment name, target bindings,
#      lifecycle status, created_at, last run and event IDs. Never an applied
#      package value.
#
# Validation. `jq` is a hard prerequisite of this module: the manifest is
# rendered with `jq -n` and validated against schemas/v1/deployment-manifest.schema.json
# with the one schema checker, schemas/v1/lib/schema-check.jq, before the atomic
# rename. There is no shell fallback and no second copy of the schema rules, so a
# jq-less host fails loudly before any mutation instead of silently skipping
# validation.
#
# Run and event IDs stay null here: Phase 6 owns run and event records, and this
# slice must not fabricate a run record. A run killed between steps leaves
# `status: applying` in the manifest, which is the discoverable interrupted
# state; classifying it as stale is Phase 6's job.
#
# Interface:
#   cloudify_state_root                              print the state root
#   cloudify_state_path <relative...>                print a path under it
#   cloudify_state_ensure_dir <dir>                  mkdir -p with mode 0700
#   cloudify_state_deployment_dir <app> <flavor> <name>
#   cloudify_state_manifest_file <app> <flavor> <name>
#   cloudify_state_lock_file <app> <flavor> <name>
#   cloudify_state_runs_dir <app> <flavor> <name>    (Phase 6)
#   cloudify_state_events_dir <year-month>           (Phase 6)
#   cloudify_state_external_host_dir <host-id>       (later phase)
#   cloudify_state_list_manifests                    one app<TAB>flavor<TAB>name<TAB>path
#   cloudify_commit_of <dir>                         print a 40-hex commit, else nothing
#   cloudify_tree_unreproducible <dir>               rc 0 when dirty or unidentified
#   cloudify_manifest_write <app> <flavor> <name> <status> <commit> <dev> <bindings-file>
#   cloudify_manifest_exists <app> <flavor> <name>
#   cloudify_manifest_field <app> <flavor> <name> <key>
#   cloudify_manifest_bindings <app> <flavor> <name>
#     one slot<TAB>address<TAB>node<TAB>instance<TAB>ssh_host per binding
#   cloudify_manifest_validate_file <file>
#   cloudify_manifest_describe <app> <flavor> <name>
#
# A bindings file is one `slot<TAB>address<TAB>node<TAB>instance<TAB>ssh_host`
# line per target slot, exactly the shape lib/runbooks.sh derives from
# cloudify_runbook_bind_targets.
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_STATE_LOADED:-}" ]] && return 0
_CLOUDIFY_STATE_LOADED=1

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vars.sh"

_CLOUDIFY_LOCK_TIMEOUT_DEFAULT=30

# The one schema directory, anchored at this module so the checker is found no
# matter what CLOUDIFY_DIR points at (a scratch tree in tests, the repo in a real
# run). CLOUDIFY_SCHEMA_DIR overrides it.
if [[ -z "${CLOUDIFY_SCHEMA_DIR:-}" ]]; then
    CLOUDIFY_SCHEMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/schemas/v1"
fi
export CLOUDIFY_SCHEMA_DIR

#== State root ==

# cloudify_state_root - the one state root. CLOUDIFY_STATE_DIR overrides it
# (tests, and an operator who keeps state somewhere else).
function cloudify_state_root() {
    if [[ -n "${CLOUDIFY_STATE_DIR:-}" ]]; then
        printf '%s\n' "$CLOUDIFY_STATE_DIR"
        return 0
    fi
    printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/cloudify"
}

# cloudify_state_path <relative...> - join a path under the state root.
function cloudify_state_path() {
    local root rel
    root=$(cloudify_state_root)
    rel=$(printf '/%s' "$@" | paste -sd/ -)
    printf '%s\n' "${root%/}${rel}"
}

# cloudify_state_ensure_dir <dir> - mkdir -p, then mode 0700.
function cloudify_state_ensure_dir() {
    local dir="${1:-}"
    [[ -n "$dir" ]] || die "cloudify_state_ensure_dir: missing directory."
    (umask 077; mkdir -p "$dir")
    chmod 700 "$dir" 2>/dev/null || true
}

# _cloudify_state_ensure_file_dir <file> - the 0700 parent of a state file.
function _cloudify_state_ensure_file_dir() {
    cloudify_state_ensure_dir "$(dirname "$1")"
}

#== Locks ==

# _cloudify_state_run_locked <lockfile> <cmd...> - run a command under one flock.
# The lock is per file and released when the subshell exits, so no process holds
# it longer than one manifest write (REDESIGN "Write protocol": manifest changes
# use one local per-deployment lock, never held together with a host lock).
function _cloudify_state_run_locked() {
    local lockfile="${1:-}"
    shift || true
    [[ -n "$lockfile" && $# -gt 0 ]] || die "Usage: _cloudify_state_run_locked <lockfile> <cmd...>"
    command -v flock >/dev/null 2>&1 ||
        die "cloudify state: 'flock' is required (util-linux) but not installed."
    _cloudify_state_ensure_file_dir "$lockfile"
    local timeout="${CLOUDIFY_LOCK_TIMEOUT:-$_CLOUDIFY_LOCK_TIMEOUT_DEFAULT}"
    (
        umask 077
        if ! flock -w "$timeout" 200; then
            die "cloudify state: lock '$lockfile' is held by another process (waited ${timeout}s)."
        fi
        "$@"
    ) 200>>"$lockfile"
}

#== Source identity: the commit in use ==

# cloudify_commit_of <dir> - the 40-hex HEAD commit of the repository at <dir>,
# or nothing when git is absent or <dir> is not a repository.
function cloudify_commit_of() {
    local dir="${1:-}"
    [[ -n "$dir" && -d "$dir" ]] || return 0
    command -v git >/dev/null 2>&1 || return 0
    git -C "$dir" rev-parse --verify HEAD 2>/dev/null || return 0
}

# cloudify_tree_unreproducible <dir> - rc 0 when <dir> is not a clean, identified
# git tree (dirty, untracked-only, or not a repository at all). rc 1 otherwise.
function cloudify_tree_unreproducible() {
    local dir="${1:-}" porcelain
    [[ -n "$dir" && -d "$dir" ]] || return 0
    command -v git >/dev/null 2>&1 || return 0
    git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1 || return 0
    porcelain=$(git -C "$dir" status --porcelain 2>/dev/null) || return 0
    [[ -z "$porcelain" ]] || return 0
    return 1
}

#== Paths and their validation ==

# cloudify_state_deployment_dir <app> <flavor> <name> - validates all three
# components before printing; a rejected component creates nothing.
function cloudify_state_deployment_dir() {
    _cloudify_identity_check_component "application" "${1:-}"
    _cloudify_identity_check_component "flavor" "${2:-}"
    _cloudify_identity_check_component "deployment name" "${3:-}"
    printf '%s\n' "$(cloudify_state_root)/deployments/${1}/${2}/${3}"
}

# cloudify_state_manifest_file <app> <flavor> <name>
function cloudify_state_manifest_file() {
    printf '%s\n' "$(cloudify_state_deployment_dir "${1:-}" "${2:-}" "${3:-}")/manifest.json"
}

# cloudify_state_lock_file <app> <flavor> <name> - the one lock per manifest.
function cloudify_state_lock_file() {
    printf '%s\n' "$(cloudify_state_deployment_dir "${1:-}" "${2:-}" "${3:-}")/.manifest.lock"
}

# cloudify_state_runs_dir <app> <flavor> <name> - Phase 6 run records.
function cloudify_state_runs_dir() {
    printf '%s\n' "$(cloudify_state_deployment_dir "${1:-}" "${2:-}" "${3:-}")/runs"
}

# cloudify_state_events_dir <year-month> - Phase 6 event records.
function cloudify_state_events_dir() {
    _cloudify_identity_check_component "event month" "${1:-}"
    printf '%s\n' "$(cloudify_state_root)/events/${1}"
}

# cloudify_state_external_host_dir <host-id> - later-phase external-host state.
function cloudify_state_external_host_dir() {
    _cloudify_identity_check_component "external host id" "${1:-}"
    printf '%s\n' "$(cloudify_state_root)/external-hosts/${1}"
}

# cloudify_state_list_manifests - one `app<TAB>flavor<TAB>name<TAB>path` per
# existing manifest, sorted. Reads only; creates nothing.
function cloudify_state_list_manifests() {
    local root manifest app flavor name
    root=$(cloudify_state_root)
    [[ -d "$root/deployments" ]] || return 0
    while IFS= read -r manifest; do
        [[ -n "$manifest" ]] || continue
        name="${manifest%/manifest.json}"
        name="${name##*/}"
        flavor="${manifest%/manifest.json}"
        flavor="${flavor%/*}"
        flavor="${flavor##*/}"
        app="${manifest%/manifest.json}"
        app="${app%/*}"
        app="${app%/*}"
        app="${app##*/}"
        printf '%s\t%s\t%s\t%s\n' "$app" "$flavor" "$name" "$manifest"
    done < <(find "$root/deployments" -mindepth 4 -maxdepth 4 -type f -name manifest.json 2>/dev/null | sort)
}

#== Manifest rendering and validation ==

# _cloudify_manifest_field_file <file> <key> - one top-level scalar field, read
# with jq. rc 1 when the file or the field is absent. A JSON null prints as
# `null`, a boolean as `true`/`false`.
function _cloudify_manifest_field_file() {
    local file="${1:-}" key="${2:-}" out
    [[ -f "$file" && -n "$key" ]] || return 1
    out=$(jq -r --arg k "$key" \
        'if has($k) then .[$k] else error("no such field: " + $k) end' "$file" 2>/dev/null) ||
        return 1
    printf '%s\n' "$out"
}

# _cloudify_manifest_parse_bindings <file> - one
# `slot<TAB>address<TAB>node<TAB>instance<TAB>ssh_host` per binding, read with jq.
# `join` (not `@tsv`) keeps the bytes exact: the schema forbids tabs, newlines and
# backslashes in these tokens, and `@tsv` would escape a backslash. A null node,
# instance or ssh_host prints empty.
function _cloudify_manifest_parse_bindings() {
    local file="${1:-}"
    [[ -f "$file" ]] || return 1
    jq -r '.bindings | to_entries[]
        | [.key, .value.address,
           (.value.node // ""), (.value.instance // ""), (.value.ssh_host // "")]
        | join("\t")' "$file" 2>/dev/null
}

# _cloudify_manifest_render ... - print the manifest on stdout with jq, the one
# encoder. An empty commit prints as JSON null (`development_override` true is
# what the schema requires beside it); empty last run/event IDs print as null.
function _cloudify_manifest_render() {
    local app="$1" flavor="$2" name="$3" status="$4" commit="$5" dev="$6"
    local created="$7" last_run="$8" last_event="$9" bindings="${10}"
    jq -n \
        --arg app "$app" --arg flavor "$flavor" --arg name "$name" \
        --arg status "$status" --arg commit "$commit" --argjson dev "$dev" \
        --arg created "$created" --arg last_run "$last_run" --arg last_event "$last_event" \
        --rawfile bindings "$bindings" '
        ($bindings
         | split("\n")
         | map(select(length > 0) | split("\t"))
         | map({key: .[0], value: {
                  address: .[1],
                  node:     (if (.[2] // "") == "" then null else .[2] end),
                  instance: (if (.[3] // "") == "" then null else .[3] end),
                  ssh_host: (if (.[4] // "") == "" then null else .[4] end)}})
         | from_entries) as $b
        | {
            schema_version: 1,
            application: $app,
            flavor: $flavor,
            deployment: $name,
            application_commit: (if $commit == "" then null else $commit end),
            development_override: $dev,
            status: $status,
            created_at: $created,
            bindings: $b,
            last_run_id: (if $last_run == "" then null else $last_run end),
            last_event_id: (if $last_event == "" then null else $last_event end)
          }'
}

# _cloudify_manifest_shape_hint <file> - name the missing and unexpected
# top-level fields, read from the schema's own `required` and `properties` (not a
# second copy of the rules). Prints nothing when the shape is fine.
function _cloudify_manifest_shape_hint() {
    local file="${1:-}" schema="$CLOUDIFY_SCHEMA_DIR/deployment-manifest.schema.json"
    jq -nr --slurpfile s "$schema" --slurpfile i "$file" '
        ($s[0].required // []) as $req
        | ($i[0] | keys) as $keys
        | (($req - $keys) | if length > 0 then "missing: " + join(", ") else empty end),
          (($keys - (($s[0].properties // {}) | keys))
           | if length > 0 then "unexpected: " + join(", ") else empty end)
    ' 2>/dev/null
}

# _cloudify_manifest_reference_check <file> - the one validator. Prints the
# rejection reason. rc 0 accepted, 1 the checker is unusable (jq or the schema
# tree is missing), 2 rejected.
function _cloudify_manifest_reference_check() {
    local file="${1:-}" checker schema hint
    command -v jq >/dev/null 2>&1 || return 1
    checker="$CLOUDIFY_SCHEMA_DIR/lib/schema-check.jq"
    schema="$CLOUDIFY_SCHEMA_DIR/deployment-manifest.schema.json"
    [[ -f "$checker" && -f "$schema" ]] || return 1
    if ! jq -e . "$file" >/dev/null 2>&1; then
        printf '%s\n' 'not valid JSON'
        return 2
    fi
    if jq -e --slurpfile schema "$schema" -f "$checker" "$file" >/dev/null 2>&1; then
        return 0
    fi
    hint=$(_cloudify_manifest_shape_hint "$file")
    printf '%s\n' "rejected by the schema${hint:+ ($(printf '%s' "$hint" | paste -sd'; ' -))}"
    return 2
}

# cloudify_manifest_validate_file <file> - fail closed with the one validator:
# the schema checker against schemas/v1/deployment-manifest.schema.json. No shell
# copy of the schema rules. jq is a hard prerequisite.
function cloudify_manifest_validate_file() {
    local file="${1:-}" rc=0 reason=""
    [[ -f "$file" ]] || die "manifest: '$file' not found."
    reason=$(_cloudify_manifest_reference_check "$file") || rc=$?
    if [[ "$rc" == "1" ]]; then
        die "manifest '$file': validation needs jq and the schema checker under '$CLOUDIFY_SCHEMA_DIR' (install it: apt-get install -y jq)."
    fi
    if [[ "$rc" == "2" ]]; then
        die "manifest '$file': $reason."
    fi
    return 0
}

#== Manifest writes ==

# _cloudify_manifest_render_write <dir> <manifest> <app> <flavor> <name> <status> <commit> <dev> <bindings-file>
# Runs inside the lock: carry created_at and the last IDs over, render, validate,
# then move into place (atomic rename; the lock is what serializes writers).
function _cloudify_manifest_render_write() {
    local dir="$1" manifest="$2" app="$3" flavor="$4" name="$5" status="$6"
    local commit="$7" dev="$8" bindings="$9"
    local created last_run last_event tmp
    created=""
    last_run=""
    last_event=""
    if [[ -f "$manifest" ]]; then
        created=$(_cloudify_manifest_field_file "$manifest" created_at) || created=""
        last_run=$(_cloudify_manifest_field_file "$manifest" last_run_id) || last_run=""
        last_event=$(_cloudify_manifest_field_file "$manifest" last_event_id) || last_event=""
        [[ "$last_run" == "null" ]] && last_run=""
        [[ "$last_event" == "null" ]] && last_event=""
    fi
    [[ -n "$created" ]] || created=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    tmp=$(mktemp "$dir/.manifest.XXXXXX") || die "manifest: cannot create a temporary file under '$dir'."
    chmod 600 "$tmp" 2>/dev/null || true
    _cloudify_manifest_render "$app" "$flavor" "$name" "$status" "$commit" "$dev" \
        "$created" "$last_run" "$last_event" "$bindings" > "$tmp"
    cloudify_manifest_validate_file "$tmp"
    mv "$tmp" "$manifest" || die "manifest: cannot move '$tmp' into place."
}

# cloudify_manifest_write <app> <flavor> <name> <status> <commit> <dev> <bindings-file>
# One manifest writer. Every write takes the manifest lock (REDESIGN: the lock is
# taken before the first manifest writer lands) and lands by atomic rename.
function cloudify_manifest_write() {
    local app="${1:-}" flavor="${2:-}" name="${3:-}" status="${4:-}"
    local commit="${5:-}" dev="${6:-}" bindings="${7:-}"
    local dir manifest lock
    command -v jq >/dev/null 2>&1 ||
        die "manifest: 'jq' is required to write deployment state (install it: apt-get install -y jq)."
    [[ -n "${app}${flavor}${name}" ]] || die "manifest: application, flavor and deployment name are all required."
    [[ "$dev" == "true" || "$dev" == "false" ]] ||
        die "manifest: development_override '$dev' is not a boolean."
    [[ -f "$bindings" ]] || die "manifest: bindings file '$bindings' not found."
    # Everything else (identity components, the status enum, the commit shape and
    # the null-commit rule) is the schema's job, checked before the atomic rename.

    dir=$(cloudify_state_deployment_dir "$app" "$flavor" "$name")
    manifest="$dir/manifest.json"
    lock="$dir/.manifest.lock"
    cloudify_state_ensure_dir "$dir"
    _cloudify_state_run_locked "$lock" _cloudify_manifest_render_write \
        "$dir" "$manifest" "$app" "$flavor" "$name" "$status" "$commit" "$dev" "$bindings"
}

# cloudify_manifest_update_status <app> <flavor> <name> <status> <commit> <dev>
# Rewrite the recorded manifest with a new status and commit, keeping its
# created_at, its bindings, and its last run and event IDs. Used at the end of a
# run: `active` after install plus verify, `degraded` on an observed failure.
function cloudify_manifest_update_status() {
    local app="${1:-}" flavor="${2:-}" name="${3:-}" status="${4:-}"
    local commit="${5:-}" dev="${6:-}" file bindings_file rc=0
    file=$(cloudify_state_manifest_file "$app" "$flavor" "$name")
    [[ -f "$file" ]] || die "manifest: '$file' not found; refusing to update a manifest that was never created."
    bindings_file=$(mktemp) || die "manifest: cannot create a bindings file."
    chmod 600 "$bindings_file" 2>/dev/null || true
    cloudify_manifest_bindings "$app" "$flavor" "$name" > "$bindings_file" || {
        rm -f "$bindings_file"
        die "manifest '$file': no bindings recorded."
    }
    cloudify_manifest_write "$app" "$flavor" "$name" "$status" "$commit" "$dev" "$bindings_file" || rc=$?
    rm -f "$bindings_file"
    return "$rc"
}

# cloudify_manifest_exists <app> <flavor> <name>
function cloudify_manifest_exists() {
    local file
    file=$(cloudify_state_manifest_file "${1:-}" "${2:-}" "${3:-}") || return 1
    [[ -f "$file" ]]
}

# cloudify_manifest_field <app> <flavor> <name> <key>
function cloudify_manifest_field() {
    local file
    file=$(cloudify_state_manifest_file "${1:-}" "${2:-}" "${3:-}")
    _cloudify_manifest_field_file "$file" "${4:-}"
}

# cloudify_manifest_bindings <app> <flavor> <name> - print one
# `slot<TAB>address<TAB>node<TAB>instance<TAB>ssh_host` per binding. rc 1 when
# the manifest or any binding is absent.
function cloudify_manifest_bindings() {
    local file
    file=$(cloudify_state_manifest_file "${1:-}" "${2:-}" "${3:-}")
    [[ -f "$file" ]] || return 1
    _cloudify_manifest_parse_bindings "$file"
}

# cloudify_manifest_describe <app> <flavor> <name> - the human read surface (no
# values). Reveals an interrupted run: `applying` is printed with its meaning.
function cloudify_manifest_describe() {
    local app="${1:-}" flavor="${2:-}" name="${3:-}" file status dev created commit
    local line slot address node instance ssh_host rest recorded=""
    file=$(cloudify_state_manifest_file "$app" "$flavor" "$name")
    [[ -f "$file" ]] || return 1
    status=$(_cloudify_manifest_field_file "$file" status)
    dev=$(_cloudify_manifest_field_file "$file" development_override)
    created=$(_cloudify_manifest_field_file "$file" created_at)
    commit=$(_cloudify_manifest_field_file "$file" application_commit)
    printf 'manifest: %s\n' "$file"
    printf 'status: %s\n' "$status"
    printf 'created_at: %s\n' "$created"
    printf 'application_commit: %s\n' "$commit"
    printf 'development_override: %s\n' "$dev"
    if [[ "$dev" == "true" ]]; then
        printf 'replayable: no\n'
        printf 'note: recorded from a dirty or unidentified tree; not exactly replayable\n'
    else
        printf 'replayable: yes\n'
    fi
    # Parse the row by hand: `read` with IFS=$'\t' collapses consecutive tabs, so
    # an external binding (node and instance null) would shift ssh_host into a
    # neighbouring field.
    recorded=$(cloudify_manifest_bindings "$app" "$flavor" "$name") || recorded=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        slot="${line%%$'\t'*}"; rest="${line#*$'\t'}"
        address="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        node="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        instance="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        ssh_host="$rest"
        printf 'binding %s: %s (node=%s instance=%s ssh=%s)\n' \
            "$slot" "$address" "${node:-<none>}" "${instance:-<none>}" "${ssh_host:-<none>}"
    done <<< "$recorded"
    if [[ "$status" == "applying" ]]; then
        printf '%s\n' 'state: applying - a run may be in flight, or it was interrupted before it could finish; classifying a stale run arrives with the run and event records (Phase 6)'
    fi
    return 0
}
