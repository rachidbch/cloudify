#!/usr/bin/env bash
# lib/deployments.sh — Deployment-wide state (ADR-011)
# The application reference (CLOUDIFY_APPLICATION, CLOUDIFY_FLAVOR,
# CLOUDIFY_DEPLOYMENT_NAME) names the desired-inputs store;
# CLOUDIFY_DEPLOYMENT stays the run id, kept per shell (parallel-safe, no shared
# file).
# Precedence: caller-env > per-(node,pkg) > deployment-wide.

[[ -n "${_CLOUDIFY_DEPLOYMENTS_LOADED:-}" ]] && return 0
_CLOUDIFY_DEPLOYMENTS_LOADED=1

# Deployment-store var read/write helpers live in lib/vars.sh.
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vars.sh"

CLOUDIFY_DEPLOYMENTS_DIR="${CLOUDIFY_CREDENTIALS_DIR:-$HOME/.config/cloudify}/deployments"

# --- Internal helpers ---

# _cloudify_deployment_dir <id> - the single-ID deployment directory (run
# snapshots, and the migration source). Rejects unsafe ids.
_cloudify_deployment_dir() {
    local id="$1"
    [[ -z "$id" ]] && die "Deployment id is required"
    [[ "$id" == *"/"* || "$id" == ".." || "$id" == "." ]] && die "Invalid deployment id: $id (no path separators)"
    echo "${CLOUDIFY_DEPLOYMENTS_DIR}/${id}"
}

# _cloudify_deployment_id_config <id> - the single-ID store
# <config-root>/deployments/<id>/config.yaml. It is not a live store: the only
# reader is `cloudify deployment migrate`, which copies it once into the nested
# path.
_cloudify_deployment_id_config() {
    echo "$(_cloudify_deployment_dir "$1")/config.yaml"
}

# cloudify_deployment_values_file <application> <flavor> <deployment>
# The nested desired-inputs store (REDESIGN "Defaults and desired inputs"):
# <deployments-root>/<application>/<flavor>/<deployment>/values.yaml. Every
# component is validated before the path is built; a rejected component creates
# no directory and no file.
function cloudify_deployment_values_file() {
    _cloudify_identity_check_component "application" "${1:-}"
    _cloudify_identity_check_component "flavor" "${2:-}"
    _cloudify_identity_check_component "deployment name" "${3:-}"
    printf '%s\n' "${CLOUDIFY_DEPLOYMENTS_DIR}/${1}/${2}/${3}/values.yaml"
}

# _cloudify_deployment_tuple_active — rc 0 when the calling process carries an
# explicit application reference (cloudify app run, or the three exports). It
# names both the application identity and the store.
function _cloudify_deployment_tuple_active() {
    [[ -n "${CLOUDIFY_APPLICATION:-}" && -n "${CLOUDIFY_FLAVOR:-}" && -n "${CLOUDIFY_DEPLOYMENT_NAME:-}" ]]
}

# _cloudify_deployment_config - the ONE desired-inputs store this process reads
# and writes: the nested values.yaml of the active application reference. rc 1
# with no output when no reference is active; the single-ID
# <id>/config.yaml is not a store, only the migration source.
function _cloudify_deployment_config() {
    _cloudify_deployment_tuple_active || return 1
    cloudify_deployment_values_file "$CLOUDIFY_APPLICATION" "$CLOUDIFY_FLAVOR" "$CLOUDIFY_DEPLOYMENT_NAME"
}

# _cloudify_deployment_require <id> - fail closed in the calling shell when no
# application reference is active, naming the command that supplies one.
function _cloudify_deployment_require() {
    _cloudify_deployment_tuple_active ||
        die "deployment '${1:-}': desired inputs live at deployments/<application>/<flavor>/<name>/values.yaml; no application reference is active (use 'cloudify app run <application>[/<flavor>]', or export CLOUDIFY_APPLICATION, CLOUDIFY_FLAVOR and CLOUDIFY_DEPLOYMENT_NAME)."
}

# _cloudify_deployment_ensure <id> — create the store dir + empty file if
# absent. Idempotent. Fails closed when no application reference is active.
_cloudify_deployment_ensure() {
    local id="$1"
    local dir config
    _cloudify_deployment_require "$id"
    config=$(_cloudify_deployment_config) || return 1
    dir=$(dirname "$config")
    mkdir -p "$dir"
    [[ -f "$config" ]] || touch "$config"
    chmod 700 "$dir"
    chmod 600 "$config" 2>/dev/null || true
}

# --- Public API (called by router) ---

# cloudify_deployment_list - list the deployment directories (a directory per
# run id, holding its run snapshots), then every current manifest (REDESIGN:
# `cloudify deployments` lists current manifests, not historical run files).
cloudify_deployment_list() {
    local d count=0
    if [[ -d "$CLOUDIFY_DEPLOYMENTS_DIR" ]]; then
        for d in "$CLOUDIFY_DEPLOYMENTS_DIR"/*/; do
            [[ -d "$d" ]] || continue
            local name; name=$(basename "$d")
            echo "$name"
            count=$((count + 1))
        done
    fi
    if declare -F cloudify_state_list_manifests >/dev/null; then
        local app flavor dep path
        while IFS=$'\t' read -r app flavor dep path; do
            [[ -n "$app" ]] || continue
            printf '%s/%s --name %s (%s)\n' "$app" "$flavor" "$dep" "$path"
            count=$((count + 1))
        done < <(cloudify_state_list_manifests)
    fi
    [[ $count -gt 0 ]] || echo "(no deployments)"
}

# --- Var management lives in lib/vars.sh ---

#== Current state read surface ==

# _cloudify_deployment_tuple_of <id> — print "application\tflavor\tname" for the
# deployment this process refers to, or rc 1 when no application identity is
# available. An explicit application reference wins; otherwise the tuple comes
# from the runbook that declares <id> (the path is the identity), never from
# splitting the deployment ID.
function _cloudify_deployment_tuple_of() {
    local id="${1:-}" runbook
    if _cloudify_deployment_tuple_active; then
        printf '%s\t%s\t%s\n' "$CLOUDIFY_APPLICATION" "$CLOUDIFY_FLAVOR" "$CLOUDIFY_DEPLOYMENT_NAME"
        return 0
    fi
    declare -F cloudify_runbook_find >/dev/null 2>&1 || return 1
    declare -F _cloudify_runbook_tuple_for >/dev/null 2>&1 || return 1
    runbook=$(cloudify_runbook_find "$id" 2>/dev/null) || return 1
    _cloudify_runbook_tuple_for "$runbook" "${CLOUDIFY_DEPLOYMENT_NAME:-default}"
}

# cloudify_deployment_show <id> — the read surface for one deployment. Prints
# the manifest (identity, status, bindings, commit, replayability) when one
# exists, and always lists the run snapshots. Never a value.
function cloudify_deployment_show() {
    local id="${1:-}" tuple app flavor name runs_dir snapshots newest
    [[ -n "$id" ]] || die "Usage: cloudify deployment show <id>"
    printf 'deployment: %s\n' "$id"

    if tuple=$(_cloudify_deployment_tuple_of "$id"); then
        IFS=$'\t' read -r app flavor name <<< "$tuple"
        printf 'application: %s/%s\n' "$app" "$flavor"
        printf 'deployment_name: %s\n' "$name"
        if ! cloudify_manifest_describe "$app" "$flavor" "$name"; then
            printf 'manifest: <none>\n'
            printf 'status: <no manifest>\n'
        fi
    else
        printf 'application: <unknown: no canonical runbook declares this deployment>\n'
    fi

    runs_dir="$CLOUDIFY_DEPLOYMENTS_DIR/$id/runs"
    if [[ -d "$runs_dir" ]]; then
        snapshots=$(find "$runs_dir" -maxdepth 1 -type f -name '*.yaml' 2>/dev/null | grep -c . || true)
        newest=$(find "$runs_dir" -maxdepth 1 -type f -name '*.yaml' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        printf 'snapshots: %s (newest: %s)\n' "$snapshots" "${newest:-<none>}"
    else
        printf 'snapshots: 0\n'
    fi
    local inputs
    if inputs=$(_cloudify_deployment_config); then
        printf 'inputs: %s\n' "$inputs"
    else
        printf 'inputs: <none: no application reference>\n'
    fi
    return 0
}

#== Migration ==

# _cloudify_deployment_values_merge <source> <target>
# Print the migration plan for one desired-inputs store; write nothing. Stdout:
# `add<TAB>NAME` for a key the target lacks, `conflict<TAB>NAME` for a key whose
# value differs, `same<TAB>NAME` for an identical key. Names only, never a value.
function _cloudify_deployment_values_merge() {
    local source="${1:-}" target="${2:-}" line key value existing
    [[ -f "$source" ]] || die "deployment migrate: source '$source' not found."
    while IFS= read -r line; do
        [[ -n "$line" && "$line" != \#* && "$line" == *:* ]] || continue
        key="${line%%:*}"
        key="${key## }"
        key="${key%% }"
        [[ -n "$key" ]] || continue
        value="${line#*: }"
        if [[ -f "$target" ]]; then
            existing=$(grep "^${key}:" "$target" 2>/dev/null | head -1 || true)
            if [[ -n "$existing" ]]; then
                if [[ "${existing#*: }" == "$value" ]]; then
                    printf 'same\t%s\n' "$key"
                else
                    printf 'conflict\t%s\n' "$key"
                fi
                continue
            fi
        fi
        printf 'add\t%s\n' "$key"
    done < "$source"
}

# _cloudify_deployment_values_apply <source> <target> <force>
# Merge the source keys into the target: a missing key is appended, a conflicting
# key is kept unless --force replaces it from the source. Never deletes a key.
# Atomic (temp + rename) under 0700/0600.
function _cloudify_deployment_values_apply() {
    local source="${1:-}" target="${2:-}" force="${3:-0}" line key value existing
    local dir tmp
    dir=$(dirname "$target")
    mkdir -p "$dir"
    chmod 700 "$dir" 2>/dev/null || true
    tmp=$(mktemp "$dir/.values.XXXXXX") || die "deployment migrate: cannot create a temporary file under '$dir'."
    chmod 600 "$tmp" 2>/dev/null || true
    [[ -f "$target" ]] && cat "$target" > "$tmp"
    # --force rewrites a conflicting key in place; otherwise the existing line stays.
    if ((force)) && [[ -f "$target" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" && "$line" != \#* && "$line" == *:* ]] || continue
            key="${line%%:*}"
            key="${key## }"
            key="${key%% }"
            [[ -n "$key" ]] || continue
            value="${line#*: }"
            existing=$(grep "^${key}:" "$tmp" 2>/dev/null | head -1 || true)
            [[ -n "$existing" && "${existing#*: }" != "$value" ]] || continue
            grep -v "^${key}:" "$tmp" > "$tmp.new" 2>/dev/null || true
            printf '%s\n' "$line" >> "$tmp.new"
            mv "$tmp.new" "$tmp"
        done < "$source"
    fi
    while IFS= read -r line; do
        [[ -n "$line" && "$line" != \#* && "$line" == *:* ]] || continue
        key="${line%%:*}"
        key="${key## }"
        key="${key%% }"
        [[ -n "$key" ]] || continue
        grep -q "^${key}:" "$tmp" 2>/dev/null && continue
        printf '%s\n' "$line" >> "$tmp"
    done < "$source"
    mv "$tmp" "$target"
    chmod 600 "$target" 2>/dev/null || true
}

# _cloudify_deployment_migrate_report <deployments-root> — the inventory-only
# migration report. It calls the reference implementation in
# schemas/v1/validate.sh (report mode: names and paths, never a value) rather
# than growing a second report. A missing script is reported, never fatal: the
# copy plan below is the load-bearing part.
function _cloudify_deployment_migrate_report() {
    local config_dir="${1:-}" nodes_dir script
    script="${CLOUDIFY_DIR:-}/schemas/v1/validate.sh"
    if [[ ! -f "$script" ]]; then
        printf 'report: %s not found; inventory report skipped\n' "$script"
        return 0
    fi
    nodes_dir="${IVPS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ivps}/nodes"
    bash "$script" report --config-dir "$config_dir" --nodes-dir "$nodes_dir"
}

# _cloudify_deployment_input_keys <file> — the KEY of every `KEY: value` line,
# one per line. Never a value.
function _cloudify_deployment_input_keys() {
    local file="${1:-}" line key
    [[ -f "$file" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" && "$line" != \#* && "$line" == *:* ]] || continue
        key="${line%%:*}"
        key="${key## }"
        key="${key%% }"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        printf '%s\n' "$key"
    done < "$file"
}

# cloudify_deployment_migrate <id> --application <app> [--flavor <flavor>]
#                                 [--name <deployment>] [--dry-run] [--force]
# One-shot bridge, deleted after the existing stores are moved: copy the
# single-ID desired-inputs store into the nested path. This is the ONLY reader
# of <config-root>/deployments/<id>/config.yaml. The application and flavor must
# be stated by the operator: the deployment ID is never split or guessed.
# Idempotent: an identical destination is a no-op; a different one is refused
# unless --force. The single-ID store is never deleted.
function cloudify_deployment_migrate() {
    local id="" app="" flavor="default" name="default" dry=0 force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --application) shift; app="${1:-}" ;;
            --flavor) shift; flavor="${1:-}" ;;
            --name) shift; name="${1:-}" ;;
            --dry-run) dry=1 ;;
            --force) force=1 ;;
            -*) die "deployment migrate: unknown flag '$1'." ;;
            *)
                [[ -z "$id" ]] || die "deployment migrate: unexpected argument '$1'."
                id="$1"
                ;;
        esac
        shift
    done
    [[ -n "$id" ]] ||
        die "Usage: cloudify deployment migrate <id> --application <application> [--flavor <flavor>] [--name <deployment>] [--dry-run] [--force]"
    [[ -n "$app" ]] ||
        die "deployment migrate: --application is required (the deployment ID '$id' is never split to guess the tuple)."
    _cloudify_identity_check_component "application" "$app"
    _cloudify_identity_check_component "flavor" "$flavor"
    _cloudify_identity_check_component "deployment name" "$name"

    local source target keys count plan adds conflicts add_count conflict_count
    source=$(_cloudify_deployment_id_config "$id")
    target=$(cloudify_deployment_values_file "$app" "$flavor" "$name")
    [[ -f "$source" ]] || die "deployment migrate '$id': no single-ID inputs at '$source'."

    printf 'application: %s/%s\n' "$app" "$flavor"
    printf 'deployment_name: %s\n' "$name"
    _cloudify_deployment_migrate_report "$(dirname "$CLOUDIFY_DEPLOYMENTS_DIR")"
    printf 'source: %s\n' "$source"
    printf 'destination: %s\n' "$target"
    keys=$(_cloudify_deployment_input_keys "$source")
    count=$(printf '%s\n' "$keys" | grep -c . || true)
    printf 'input keys (names only, %s): %s\n' "$count" "$(printf '%s' "$keys" | paste -sd, -)"

    plan=$(_cloudify_deployment_values_merge "$source" "$target")
    adds=$(printf '%s\n' "$plan" | awk -F'\t' '$1 == "add" { print $2 }' | paste -sd, -)
    conflicts=$(printf '%s\n' "$plan" | awk -F'\t' '$1 == "conflict" { print $2 }' | paste -sd, -)
    add_count=$(printf '%s\n' "$plan" | grep -c $'^add\t' || true)
    conflict_count=$(printf '%s\n' "$plan" | grep -c $'^conflict\t' || true)
    printf 'add (names only): %s\n' "${adds:-<none>}"
    printf 'conflict (names only): %s\n' "${conflicts:-<none>}"

    if [[ "$add_count" -eq 0 && "$conflict_count" -eq 0 ]]; then
        printf 'result: already migrated (%s key names present and identical); nothing to do\n' "$count"
        return 0
    fi

    if [[ "$conflict_count" -gt 0 ]] && ((!force)); then
        die "deployment migrate '$id': the destination '$target' already holds different values for: $conflicts. Refusing to overwrite them; re-run with --force to take the single-ID store's values for those keys."
    fi

    if ((dry)); then
        printf 'result: dry run, nothing written\n'
        return 0
    fi

    _cloudify_deployment_values_apply "$source" "$target" "$force"
    printf 'result: migrated (%s key names added%s)\n' "$add_count" \
        "${conflicts:+; $conflicts overwritten from the single-ID store}"
    return 0
}
