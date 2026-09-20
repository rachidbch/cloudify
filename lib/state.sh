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
# other control characters in these tokens, but it allows a backslash, which
# `@tsv` would escape. A null node, instance or ssh_host prints empty.
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
         | map(if length != 5 then error("a binding line must have 5 tab-separated fields") else . end)
         | (. as $rows | ($rows | map(.[0])) as $keys
            | if ($keys | length) != ($keys | unique | length)
              then error("duplicate binding slot") else $rows end)
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

# --- inventory paths (ADR-026): the tree lives on the host, under the
# id-keyed directory ivps hands back; the host lock sits beside it. ---

# cloudify_state_inventory_root <node> [<instance>] - the per-node inventory
# root: the id-keyed directory ivps hands back for the host. A host the local
# ivps inventory cannot resolve is a named error before anything is created
# (the local-inventory prerequisite).
function cloudify_state_inventory_root() {
    local node="${1:?}" inst="${2:-}"
    command -v ivps >/dev/null 2>&1 ||
        die "inventory: 'ivps' is required to resolve the node path (the local-inventory prerequisite)."
    local d
    d=$(ivps node path "$node${inst:+:$inst}") ||
        die "inventory: the local ivps inventory cannot resolve '$node${inst:+:$inst}' (host unknown or node path failed)."
    [[ -n "$d" ]] || die "inventory: 'ivps node path $node${inst:+:$inst}' returned nothing."
    printf '%s/deployments\n' "$d"
}

# cloudify_state_host_lock_path <node> [<instance>] - the one host mutation
# lock, keyed by the host only (never by package or instance).
function cloudify_state_host_lock_path() {
    local node="${1:?}" inst="${2:-}"
    local root
    root=$(cloudify_state_inventory_root "$node" "${inst:-}")
    printf '%s/cloudify/.host-mutation.lock\n' "$(dirname "$root")"
}

# _cloudify_state_check_package <name> - the package-name shape from the
# inventory schema.
_cloudify_state_check_package() {
    [[ "${1:-}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
        die "Invalid package name '${1:-}' (leading alphanumeric, then lowercase, digits, '.' '_' '-')."
}

# cloudify_state_record_dir <node> [<instance>] <app> <flavor> <deployment>
#   <package> <instance> - the per-deployment inventory record directory on
# the host; every component is validated before anything is printed.
function cloudify_state_record_dir() {
    local node="${1:?}" inst="${2:-}" app="${3:?}" flavor="${4:?}" dep="${5:?}" pkg="${6:?}" key="${7:?}"
    _cloudify_identity_check_component "application" "$app"
    _cloudify_identity_check_component "flavor" "$flavor"
    _cloudify_identity_check_component "deployment name" "$dep"
    _cloudify_state_check_package "$pkg"
    _cloudify_identity_check_instance "package instance" "$key"
    printf '%s/%s/%s/%s/packages/%s/%s\n' \
        "$(cloudify_state_inventory_root "$node" "${inst:-}")" "$app" "$flavor" "$dep" "$pkg" "$key"
}

# cloudify_state_host_baseline_path <capture-root> - the ADR-028 host record:
# origin (image, created_at; discovered/asserted/unknown) beside the
# continuity anchor, written once at first inventory write.
function cloudify_state_host_baseline_path() {
    printf '%s/cloudify/host.json\n' "${1:?}"
}

# cloudify_state_host_baseline_init <capture-root> <discovered|asserted|unknown> [origin-json]
# - create-if-absent (hard link), never overwriting: the origin is recorded
# once; `discovered` reads the engine-sourced record through the local ivps
# inventory, `asserted` takes the operator's origin JSON, `unknown` records
# that nothing could answer. Idempotent: an existing record is a no-op.
function cloudify_state_host_baseline_init() {
    local root="${1:?}" mode="${2:-}"
    local bp
    bp=$(cloudify_state_host_baseline_path "$root")
    [[ -f "$bp" ]] && return 0
    _cloudify_state_event_require_tools
    local host_id origin_json="null"
    host_id=$(basename "$root")
    if [[ "$mode" == discovered ]]; then
        if command -v ivps >/dev/null 2>&1 && \
            origin_json=$(ivps node show "${CLOUDIFY_BASELINE_TARGET:-$host_id}" --json 2>/dev/null); then
            : # engine-sourced facts captured below
        else
            origin_json="null"
            mode="unknown"
        fi
    fi
    mkdir -p "$(dirname "$bp")"
    [[ -n "$origin_json" ]] || origin_json="null"
    local tmp="$bp.tmp$$"
    jq -n --arg host_id "$host_id" --arg mode "$mode" \
        --argjson origin "$origin_json" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
        {schema_version: 1,
         origin: {mode: $mode,
                  image: ($origin.image // null),
                  created_at: ($origin.created_at // null),
                  engine: ($origin.engine // null)},
         continuity: {host_id: $host_id, boot_id: null},
         recorded_at: $ts}' > "$tmp" \
        || { rm -f "$tmp"; die "baseline: cannot render the host origin."; }
    mkdir -p "$(dirname "$bp")"
    chmod 600 "$tmp"
    sync "$tmp" 2>/dev/null || true
    if ! ln "$tmp" "$bp" 2>/dev/null; then
        rm -f "$tmp"
        [[ -f "$bp" ]] && return 0
        die "baseline: could not commit '$bp'."
    fi
    rm -f "$tmp"
    sync -d "$(dirname "$bp")" 2>/dev/null || true
    return 0
}

# cloudify_state_host_baseline_check <capture-root> <observed-boot-id> - the
# ADR-028 continuity comparison: the machine present must be the machine the
# baseline describes. Same boot id: refreshes last-seen and passes. A changed
# boot id on the same host id means the machine was rewound or replaced: a
# named refusal, never a silent mutation. No baseline: rc 1 (caller inits).
function cloudify_state_host_baseline_check() {
    local root="${1:?}" boot="${2:?}" bp
    bp=$(cloudify_state_host_baseline_path "$root")
    [[ -f "$bp" ]] || { printf 'baseline: none at %s\n' "$bp"; return 1; }
    local last
    last=$(jq -r '.continuity.boot_id // empty' "$bp")
    if [[ -n "$last" && "$last" != "$boot" ]]; then
        printf 'baseline: host %s was rewound or replaced (last-seen boot %s, now %s); verify or re-adopt.\n' \
            "$(jq -r .continuity.host_id "$bp")" "$last" "$boot"
        return 2
    fi
    local tmp="$bp.tmp$$"
    if ! jq --arg boot "$boot" '.continuity.boot_id = $boot' "$bp" > "$tmp" \
            || ! mv "$tmp" "$bp"; then
        rm -f "$tmp"
        die "baseline: cannot record last-seen boot id."
    fi
    return 0
}

# cloudify_state_event_id - UTC second plus 8 random hex from /dev/urandom.
# Collision handling belongs to the event writer's create-if-absent link,
# which regenerates; the generator itself is pure and never overwrites.
function cloudify_state_event_id() {
    printf '%s-%s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
}

# cloudify_state_writer_identity - who is writing, read once per worker:
# hostname, kernel boot id, pid, process start ticks (proc stat field 22 -
# what distinguishes a reused pid) and the cloudify tool version. Cached in
# the worker so every event of one dispatch carries identical identity.
_CLOUDIFY_STATE_WRITER=""
function cloudify_state_writer_identity() {
    if [[ -z "$_CLOUDIFY_STATE_WRITER" ]]; then
        local ticks
        ticks=$(cut -d' ' -f22 /proc/$$/stat)
        local version="${CLOUDIFY_VERSION:-}"
        [[ -n "$version" ]] || version=$(git -C "${CLOUDIFY_SCHEMA_DIR%/schemas/v1}" describe --always --dirty 2>/dev/null || echo unknown)
        _CLOUDIFY_STATE_WRITER=$(jq -n \
            --arg host "$(hostname)" \
            --arg boot "$(cat /proc/sys/kernel/random/boot_id)" \
            --argjson pid "$$" \
            --argjson ticks "$ticks" \
            --arg tool "$version" \
            '{host: $host, boot_id: $boot, pid: $pid, process_start_ticks: $ticks, tool_version: $tool}')
    fi
    printf '%s\n' "$_CLOUDIFY_STATE_WRITER"
}

# cloudify_state_events_root - the event root under the Cloudify state root:
# audit records are per-run history, not node architecture (ADR-026).
function cloudify_state_events_root() {
    printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/cloudify/events"
}

function _cloudify_state_event_require_tools() {
    command -v jq >/dev/null 2>&1 ||
        die "event: 'jq' is required to write events (install it: apt-get install -y jq)."
    [[ -f "$CLOUDIFY_SCHEMA_DIR/event.schema.json" && -f "$CLOUDIFY_SCHEMA_DIR/lib/schema-check.jq" ]] ||
        die "event: the schema checker is missing under '$CLOUDIFY_SCHEMA_DIR'."
}

# cloudify_state_event_create <body-file> [event-id] - the one immutable event
# writer. Renders body + event_id (+ `at` when the body has none) into a 0600
# temporary in the destination, validates against event.schema.json, flushes,
# then hard-links create-if-absent and flushes the directory. An existing name
# is never overwritten: generated ids regenerate (bounded at three), a pinned
# id fails loudly. Prints the committed event id.
function cloudify_state_event_create() {
    local body="${1:-}" id="${2:-}"
    [[ -f "$body" ]] || die "event: body file '$body' missing."
    _cloudify_state_event_require_tools
    local root final tmp tries=0 body_json
    while :; do
        [[ -n "$id" ]] || id=$(cloudify_state_event_id)
        root=$(cloudify_state_events_root)
        final="$root/${id:0:4}-${id:4:2}/$id.json"
        if [[ -e "$final" ]]; then
            if [[ -n "${2:-}" ]]; then
                die "event: '$final' already exists; refusing to overwrite a pinned event id."
            fi
            id=""
            tries=$((tries + 1))
            (( tries < 3 )) || die "event: no free event id after 3 attempts."
            continue
        fi
        mkdir -p "$(dirname "$final")"
        body_json=$(jq -c --arg id "$id" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
            .event_id = $id
            | if (has("at") and .at != null) then . else .at = $now end' "$body") \
            || die "event: body '$body' is not valid JSON."
        tmp=$(mktemp "$(dirname "$final")/.event-XXXXXX.json")
        printf '%s\n' "$body_json" > "$tmp"
        chmod 600 "$tmp"
        if ! cloudify_state_validate_file "$CLOUDIFY_SCHEMA_DIR/event.schema.json" "$tmp" >/dev/null; then
            rm -f "$tmp"
            die "event: the rendered event failed schema validation."
        fi
        sync "$tmp" 2>/dev/null || true
        if ln "$tmp" "$final" 2>/dev/null; then
            rm -f "$tmp"
            sync -d "$(dirname "$final")" 2>/dev/null || true
            printf '%s\n' "$id"
            return 0
        fi
        rm -f "$tmp"
        if [[ -e "$final" ]]; then
            if [[ -n "${2:-}" ]]; then
                die "event: '$final' already exists; refusing to overwrite a pinned event id."
            fi
            id=""
            tries=$((tries + 1))
            (( tries < 3 )) || die "event: no free event id after 3 attempts."
            continue
        fi
        die "event: could not hard-link the event into '$final'."
    done
}

# _cloudify_state_event_refs <record> - the event ids one record links to
# (applied, last attempt, health; absent when the object is null). One jq read.
function _cloudify_state_event_refs() {
    jq -r '.applied.event_id // empty, (.last_attempt | if . then .event_id else empty end), .health.event_id // empty' "$1"
}

# cloudify_state_inventory_check <record> - subject-level gap check: rc 0 when
# the record is schema-valid and every referenced event is committed; rc 2
# names the first gap; rc 1 when the record is missing or invalid. Read-only.
function cloudify_state_inventory_check() {
    local record="${1:?}" eid
    [[ -f "$record" ]] || { printf 'inventory check: no record at %s\n' "$record"; return 1; }
    cloudify_state_validate_file "$CLOUDIFY_SCHEMA_DIR/package-state.schema.json" "$record" >/dev/null \
        || { printf 'inventory check: %s is not a valid record\n' "$record"; return 1; }
    while IFS= read -r eid; do
        [[ -n "$eid" ]] || continue
        if [[ ! -f "$(cloudify_state_events_root)/${eid:0:4}-${eid:4:2}/$eid.json" ]]; then
            printf 'inventory check: %s references missing event %s\n' "$record" "$eid"
            return 2
        fi
    done < <(_cloudify_state_event_refs "$record")
    return 0
}

# cloudify_state_inventory_apply <record-path> <event-body> <next-capture> -
# the event-first inventory transition. Reads and validates the current record
# (conceptual revision 0 when absent), refuses a record pointing at a missing
# event, stamps the next capture (revision +1; the new event id on every object
# the transition changed), validates event and capture, hard-links the event,
# then atomically replaces the record and re-reads it before reporting
# success. Prints the committed event id.
function cloudify_state_inventory_apply() {
    local record="${1:?}" event_body="${2:?}" next="${3:?}"
    command -v jq >/dev/null 2>&1 ||
        die "inventory: 'jq' is required to write state."
    [[ -f "$CLOUDIFY_SCHEMA_DIR/package-state.schema.json" && -f "$CLOUDIFY_SCHEMA_DIR/event.schema.json" && -f "$CLOUDIFY_SCHEMA_DIR/lib/schema-check.jq" ]] ||
        die "inventory: the schema tree is missing under '$CLOUDIFY_SCHEMA_DIR'."
    [[ -f "$event_body" && -f "$next" ]] || die "inventory: event body or next capture missing."

    local cur_rev=0 cur_empty=true
    if [[ -f "$record" ]]; then
        cloudify_state_validate_file "$CLOUDIFY_SCHEMA_DIR/package-state.schema.json" "$record" >/dev/null \
            || die "inventory: '$record' is not a valid record; refusing to mutate."
        cur_rev=$(jq -r '.revision' "$record")
        cur_empty=false
        local eid
        while IFS= read -r eid; do
            [[ -n "$eid" ]] || continue
            if [[ ! -f "$(cloudify_state_events_root)/${eid:0:4}-${eid:4:2}/$eid.json" ]]; then
                die "inventory: '$record' references missing event '$eid'; verify before mutating."
            fi
        done < <(_cloudify_state_event_refs "$record")
    fi
    local next_rev=$((cur_rev + 1))

    local id workdir
    workdir=$(dirname "$record")
    id=$(cloudify_state_event_id)
    mkdir -p "$workdir"
    local cap_tmp ev_dir ev_tmp
    cap_tmp=$(mktemp "$workdir/.inventory-XXXXXX.json")
    ev_dir=$(cloudify_state_events_root)/${id:0:4}-${id:4:2}
    mkdir -p "$ev_dir"
    ev_tmp=$(mktemp "$ev_dir/.event-XXXXXX.json")

    jq --slurpfile cur <(if [[ "$cur_empty" == true ]]; then echo '{}'; else cat "$record"; fi) \
        --argjson rev "$next_rev" --arg eid "$id" '
        . as $next | $cur[0] as $cur
        | .revision = $rev
        | .applied = (if $next.applied == $cur.applied then $next.applied
                      else (if $next.applied == null then null else ($next.applied | .event_id = $eid) end) end)
        | .last_attempt = (if $next.last_attempt == $cur.last_attempt then $next.last_attempt
                      else (if $next.last_attempt == null then null else ($next.last_attempt | .event_id = $eid) end) end)
        | .health = (if $next.health == $cur.health then $next.health
                      else (if $next.health == null then null else ($next.health | .event_id = $eid) end) end)
    ' "$next" > "$cap_tmp" \
        || { rm -f "$cap_tmp" "$ev_tmp"; die "inventory: the next capture is not valid JSON."; }
    if ! cloudify_state_validate_file "$CLOUDIFY_SCHEMA_DIR/package-state.schema.json" "$cap_tmp" >/dev/null; then
        rm -f "$cap_tmp" "$ev_tmp"
        die "inventory: the next capture failed schema validation; nothing written."
    fi

    jq --arg id "$id" --argjson prev "$cur_rev" --argjson result "$next_rev" '
        .event_id = $id
        | .state = {previous_revision: $prev, resulting_revision: $result}' "$event_body" > "$ev_tmp" \
        || { rm -f "$cap_tmp" "$ev_tmp"; die "inventory: the event body is not valid JSON."; }
    if ! cloudify_state_validate_file "$CLOUDIFY_SCHEMA_DIR/event.schema.json" "$ev_tmp" >/dev/null; then
        rm -f "$cap_tmp" "$ev_tmp"
        die "inventory: the rendered event failed schema validation; nothing written."
    fi

    chmod 600 "$cap_tmp" "$ev_tmp"
    sync "$cap_tmp" "$ev_tmp" 2>/dev/null || true
    if ! ln "$ev_tmp" "$ev_dir/$id.json" 2>/dev/null; then
        rm -f "$cap_tmp" "$ev_tmp"
        die "inventory: could not commit event '$id'."
    fi
    rm -f "$ev_tmp"
    sync -d "$ev_dir" 2>/dev/null || true
    if ! mv "$cap_tmp" "$record" 2>/dev/null; then
        die "inventory: the event '$id' is committed but the capture replace failed; repair before mutating (state check)."
    fi
    sync -d "$workdir" 2>/dev/null || true

    local got_rev got_id
    got_rev=$(jq -r '.revision' "$record")
    got_id=$(jq -r '.applied.event_id // .last_attempt.event_id // .health.event_id' "$record")
    [[ "$got_rev" == "$next_rev" && ("$got_id" == "$id" || -f "$(cloudify_state_events_root)/${id:0:4}-${id:4:2}/$id.json") ]] \
        || die "inventory: the committed record does not read back revision $next_rev with event $id."
    printf '%s\n' "$id"
}

# _cloudify_manifest_require_tools - jq and the schema tree, checked before any
# write. A host that cannot validate a manifest must not create one.
function _cloudify_manifest_require_tools() {
    command -v jq >/dev/null 2>&1 ||
        die "manifest: 'jq' is required to write deployment state (install it: apt-get install -y jq)."
    [[ -f "$CLOUDIFY_SCHEMA_DIR/lib/schema-check.jq" && -f "$CLOUDIFY_SCHEMA_DIR/deployment-manifest.schema.json" ]] ||
        die "manifest: the schema checker is missing under '$CLOUDIFY_SCHEMA_DIR'."
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

# cloudify_state_validate_file <schema> <file> - the one generic schema
# validator: any schema in the tree, any file. Prints the rejection reason.
# rc 0 accepted, 1 the checker is unusable (jq or a missing input), 2 rejected.
function cloudify_state_validate_file() {
    local schema="${1:-}" file="${2:-}"
    [[ -f "$schema" && -f "$file" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    [[ -f "$CLOUDIFY_SCHEMA_DIR/lib/schema-check.jq" ]] || return 1
    if ! jq -e . "$file" >/dev/null 2>&1; then
        printf '%s\n' 'not valid JSON'
        return 2
    fi
    if jq -e --slurpfile schema "$schema" -f "$CLOUDIFY_SCHEMA_DIR/lib/schema-check.jq" "$file" >/dev/null 2>&1; then
        return 0
    fi
    printf '%s\n' "rejected by the schema"
    return 2
}

# _cloudify_manifest_reference_check <file> - the manifest validation front:
# delegates to cloudify_state_validate_file and enriches the rejection with the
# manifest shape hint (missing/unexpected fields from the schema itself).
# rc 0 accepted, 1 the checker is unusable (jq or the schema tree is missing), 2 rejected.
function _cloudify_manifest_reference_check() {
    local file="${1:-}" schema="$CLOUDIFY_SCHEMA_DIR/deployment-manifest.schema.json" rc=0
    command -v jq >/dev/null 2>&1 || return 1
    [[ -f "$CLOUDIFY_SCHEMA_DIR/lib/schema-check.jq" && -f "$schema" ]] || return 1
    cloudify_state_validate_file "$schema" "$file" && return 0
    rc=$?
    [[ $rc -eq 2 ]] || return $rc
    local hint
    hint=$(_cloudify_manifest_shape_hint "$file")
    printf '%s\n' "rejected by the schema${hint:+ ($(printf '%s' "$hint" | paste -sd'; ' -))}"
    return 2
}

# cloudify_manifest_validate_file <file> - the one validator. Fail closed:
# prints the reason on stderr and rc 1. It never exits, so the writer can remove
# its temporary file before aborting.
function cloudify_manifest_validate_file() {
    local file="${1:-}" rc=0 reason=""
    [[ -f "$file" ]] || { printf "manifest: '%s' not found.\n" "$file" >&2; return 1; }
    reason=$(_cloudify_manifest_reference_check "$file") || rc=$?
    if [[ "$rc" == "1" ]]; then
        printf "manifest '%s': validation needs jq and the schema checker under '%s' (install it: apt-get install -y jq).\n" "$file" "$CLOUDIFY_SCHEMA_DIR" >&2
        return 1
    fi
    if [[ "$rc" == "2" ]]; then
        printf "manifest '%s': %s.\n" "$file" "$reason" >&2
        return 1
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
    if ! _cloudify_manifest_render "$app" "$flavor" "$name" "$status" "$commit" "$dev" \
        "$created" "$last_run" "$last_event" "$bindings" > "$tmp"; then
        rm -f "$tmp"
        die "manifest: cannot render the manifest under '$dir'."
    fi
    if ! cloudify_manifest_validate_file "$tmp"; then
        rm -f "$tmp"
        die "manifest: the rendered manifest under '$dir' did not validate."
    fi
    mv "$tmp" "$manifest" || die "manifest: cannot move '$tmp' into place."
}

# cloudify_manifest_write <app> <flavor> <name> <status> <commit> <dev> <bindings-file>
# One manifest writer. Every write takes the manifest lock (REDESIGN: the lock is
# taken before the first manifest writer lands) and lands by atomic rename.
function cloudify_manifest_write() {
    local app="${1:-}" flavor="${2:-}" name="${3:-}" status="${4:-}"
    local commit="${5:-}" dev="${6:-}" bindings="${7:-}"
    local dir manifest lock
    # The tools and the schema tree are checked BEFORE anything is created, so a
    # host that cannot validate never gets a deployment directory or a lock file.
    _cloudify_manifest_require_tools
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
    recorded=$(cloudify_manifest_bindings "$app" "$flavor" "$name") ||
        die "manifest '$file': cannot read the recorded bindings."
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
