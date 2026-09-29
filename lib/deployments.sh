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

# cloudify_deployment_list - the current manifests. A legacy single-ID run
# directory or a desired-inputs directory is not a deployment on its own; only
# the manifest the run wrote is (REDESIGN: list current manifests, not
# historical run files).
cloudify_deployment_list() {
    local app flavor dep _path count=0
    local status sdisp slot node instance rest bline rec n uv hosts pkgs hplural uvplural uvdisp
    local -A seen_uv
    if declare -F cloudify_state_list_manifests >/dev/null; then
        while IFS=$'\t' read -r app flavor dep _path; do
            [[ -n "$app" ]] || continue
            count=$((count + 1))
            status=$(cloudify_manifest_field "$app" "$flavor" "$dep" status 2>/dev/null) || status="-"
            [[ "$status" == "null" || -z "$status" ]] && status="-"
            sdisp="$status"
            [[ "$status" == verified ]] && sdisp="${GREEN}verified${RESET}"
            [[ "$status" == degraded ]] && sdisp="${RED}degraded${RESET}"
            hosts=0 pkgs=0 uv=0
            seen_uv=()
            local bf
            bf=$(mktemp "$CLOUDIFY_TMP/list-bindings-XXXXXX")
            cloudify_manifest_bindings "$app" "$flavor" "$dep" > "$bf" 2>/dev/null || true
            while IFS= read -r bline; do
                [[ -n "$bline" ]] || continue
                hosts=$((hosts + 1))
                slot="${bline%%$'\t'*}"
                rest="${bline#*$'\t'}"          # address TAB node TAB instance TAB ssh
                rest="${rest#*$'\t'}"           # skip the address field
                node="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
                instance="${rest%%$'\t'*}"
                local root
                root=$(cloudify_state_inventory_root "$node" "$instance" 2>/dev/null) || continue
                while IFS= read -r rec; do
                    [[ -f "$rec" ]] || continue
                    pkgs=$((pkgs + 1))
                    while IFS= read -r n; do
                        [[ -n "$n" ]] && seen_uv["$n"]=1
                    done < <(jq -r '.applied.values // {} | to_entries[] | select(.value.source == "caller") | .key' "$rec" 2>/dev/null)
                done < <(find "$root/$app/$flavor/$dep/packages" -mindepth 3 -maxdepth 3 -name state.json 2>/dev/null | sort)
            done < "$bf"
            rm -f "$bf"
            for n in "${!seen_uv[@]}"; do uv=$((uv + 1)); done
            hplural="s"; (( hosts == 1 )) && hplural=""
            uvdisp="-"
            if (( uv > 0 )); then
                uvplural="s"; (( uv == 1 )) && uvplural=""
                uvdisp="$uv user value$uvplural"
                [[ -n "${YELLOW:-}" ]] && uvdisp="${YELLOW}$uv user value$uvplural${RESET}"
            fi
            printf '%s/%s/%s\t%s\t%d pkgs\t%d host%s\t%s\n' \
                "$app" "$flavor" "$dep" "$sdisp" "$pkgs" "$hosts" "$hplural" "$uvdisp"
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
    local id="${1:-}" name="${2:-default}" runbook
    if _cloudify_deployment_tuple_active; then
        printf '%s\t%s\t%s\n' "$CLOUDIFY_APPLICATION" "$CLOUDIFY_FLAVOR" "$CLOUDIFY_DEPLOYMENT_NAME"
        return 0
    fi
    declare -F cloudify_runbook_find_app >/dev/null 2>&1 || return 1
    declare -F _cloudify_runbook_tuple_for >/dev/null 2>&1 || return 1
    local app="" flavor=""
    case "$id" in
        */*) app="${id%%/*}"; flavor="${id#*/}" ;;
        *) app="$id"; flavor="default" ;;
    esac
    runbook=$(cloudify_runbook_find_app "$app" "$flavor" 2>/dev/null) || return 1
    _cloudify_runbook_tuple_for "$runbook" "$name"
}

# cloudify_deployment_show <id> — the read surface for one deployment. Prints
# the manifest (identity, status, bindings, commit, replayability) when one
# exists, and always lists the run snapshots. Never a value.
function cloudify_deployment_show() {
    local id="${1:-}" user_only="${2:-}" name="${3:-default}" tuple app flavor dname runs_dir snapshots newest
    [[ -n "$id" ]] || die "Usage: cloudify deployment show <application>[/<flavor>] [--name <name>] [--user-values]"
    printf 'deployment: %s\n' "$id"

    if tuple=$(_cloudify_deployment_tuple_of "$id" "$name"); then
        IFS=$'\t' read -r app flavor dname <<< "$tuple"
        printf 'application: %s/%s\n' "$app" "$flavor"
        printf 'deployment_name: %s\n' "$dname"
        if ! cloudify_manifest_describe "$app" "$flavor" "$dname"; then
            printf 'manifest: <none>\n'
            printf 'status: <no manifest>\n'
        fi
        if [[ -n "$user_only" ]]; then
            printf 'values in effect (user only):\n'
        else
            printf 'values in effect:\n'
        fi
        cloudify_deployment_applied_screen "$app" "$flavor" "$dname" "$user_only"
    else
        printf 'application: <unknown: no canonical runbook declares this deployment>\n'
    fi

    runs_dir=$(cloudify_state_runs_dir "${app:-}" "${flavor:-}" "${dname:-$name}" 2>/dev/null) || runs_dir=""
    if [[ -n "$runs_dir" && -d "$runs_dir" ]]; then
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

#== Applied-state read surface and the unset escape (4.4, ADR-030) ==

# _cloudify_deployment_value_line <name> <value-json> - one screen line of an
# applied value: secrets as dots plus a short purple fingerprint (never the
# text), secret references as the reference, literals as their capped source
# form. The USER marker column prints only for caller-sourced values - the
# yellow stripe against blank is the screen's staple.
_cloudify_deployment_value_line() {
    local name="$1" v="$2"
    local source secret redacted digest form display usercol
    source=$(jq -r .source <<<"$v")
    secret=$(jq -r .secret <<<"$v")
    redacted=$(jq -r .redacted <<<"$v")
    if [[ "$secret" == true && "$redacted" == true ]]; then
        digest=$(jq -r .digest <<<"$v")          # sha256:<64hex>
        display="${PURPLE}********  ${digest:7:8}${RESET}"
    elif [[ "$secret" == true ]]; then
        display=$(jq -r .reference <<<"$v")
    else
        form=$(jq -r .source_form <<<"$v")
        (( ${#form} > 24 )) && form="${form:0:24}…"
        display="$form"
    fi
    usercol=""
    [[ "$source" == caller ]] && usercol="${YELLOW}USER${RESET}"
    printf '      %-18s %-32s %b\n' "$name" "$display" "$usercol"
}

# cloudify_deployment_applied_screen <app> <flavor> <name> [user-only]
# The applied-state block: one host section per manifest binding, each
# package with its values in effect nested under it. User values carry the
# yellow USER marker; the footer names the exact release commands.
cloudify_deployment_applied_screen() {
    local app="$1" flavor="$2" name="$3" user_only="${4:-}"
    local bf bline slot node instance rest display
    local -A user_pkg=() user_seen=()
    bf=$(mktemp "$CLOUDIFY_TMP/depl-bindings-XXXXXX")
    cloudify_manifest_bindings "$app" "$flavor" "$name" > "$bf" || {
        rm -f "$bf"
        printf 'values in effect: no hosts bound\n'
        return 0
    }
    local total_hosts=0
    while IFS= read -r bline; do [[ -n "$bline" ]] && total_hosts=$((total_hosts + 1)); done < "$bf"

    while IFS= read -r bline; do
        [[ -n "$bline" ]] || continue
        slot="${bline%%$'\t'*}"
        rest="${bline#*$'\t'}"          # address TAB node TAB instance TAB ssh
        rest="${rest#*$'\t'}"           # skip the address field
        node="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        instance="${rest%%$'\t'*}"
        display="${node}${instance:+:$instance}"
        if (( total_hosts > 1 )); then
            printf '  %s -> %s\n' "$slot" "$display"
        else
            printf '  %s\n' "$display"
        fi
        local root rec pkg inst version status at line v
        root=$(cloudify_state_inventory_root "$node" "$instance")
        local -a recs=()
        while IFS= read -r rec; do
            [[ -n "$rec" ]] || continue
            recs+=("$rec")
        done < <(find "$root/$app/$flavor/$name/packages" -mindepth 3 -maxdepth 3 -name state.json 2>/dev/null | sort)
        if (( ${#recs[@]} == 0 )); then
            printf '    (no packages recorded on %s)\n' "$display"
            continue
        fi
        for rec in "${recs[@]}"; do
            pkg="$(basename "$(dirname "$(dirname "$rec")")")"
            inst="$(basename "$(dirname "$rec")")"
            # user-only mode: a package with no pinned values drops out whole.
            if [[ -n "$user_only" ]]; then
                local caller_count
                caller_count=$(jq -r '[.applied.values // {} | to_entries[] | select(.value.source == "caller")] | length' "$rec" 2>/dev/null) || caller_count=0
                (( ${caller_count:-0} > 0 )) || continue
            fi
            version=$(jq -r '.applied.version // "-"' "$rec" 2>/dev/null)
            status=$(jq -r '.health.status // "unknown"' "$rec" 2>/dev/null)
            at=$(jq -r '.applied.at // ""' "$rec" 2>/dev/null)
            local sdisp="$status" failinfo=""
            [[ "$status" == ok ]] && sdisp="${GREEN}ok${RESET}"
            [[ "$status" == degraded ]] && sdisp="${RED}degraded${RESET}"
            if [[ "$(jq -r '.last_attempt.outcome // ""' "$rec" 2>/dev/null)" == failed ]]; then
                local lat
                lat=$(jq -r '.last_attempt.at // ""' "$rec" 2>/dev/null)
                failinfo=" ${RED}last try failed ${lat:5:5} ${lat:11:5}${RESET}"
            fi
            printf '    %-14s %-10s %-9s %s %s%s\n' "$pkg" "$version" "$sdisp" "${at:5:5}" "${at:11:5}" "$failinfo"
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                v=$(jq -c --arg k "${line%%$'\t'*}" '.[$k]' <<<"$(jq -c '.applied.values // {}' "$rec")")
                local vname="${line%%$'\t'*}" vsource
                vsource=$(jq -r .source <<<"$v")
                [[ -n "$user_only" && "$vsource" != caller ]] && continue
                _cloudify_deployment_value_line "$vname" "$v"
                if [[ "$vsource" == caller ]]; then
                    user_seen[$vname]=1
                    user_pkg[$vname]="$pkg"
                fi
            done < <(jq -r '(.applied.values // {}) | to_entries | sort_by(.key)[] | "\(.key)\t\(.value.source)"' "$rec" 2>/dev/null)
        done
    done < "$bf"
    rm -f "$bf"

    local n=0 vname
    for vname in "${!user_seen[@]}"; do n=$((n + 1)); done
    if (( n == 1 )); then
        printf '  1 user value outranks the store - release it:\n'
    elif (( n > 1 )); then
        printf '  %d user values outrank the store - release one:\n' "$n"
    fi
    if (( n > 0 )); then
        for vname in "${!user_seen[@]}"; do
            printf '  cloudify deployment unset %s/%s/%s %s %s\n' "$app" "$flavor" "$name" "${user_pkg[$vname]}" "$vname"
        done
    fi
    return 0
}

# cloudify_deployment_unset <id> <package> <VAR>...
# Release user pins: every applied record of this deployment+package that
# holds one of the named values as caller-sourced transitions it to source
# `applied` - the value stays in effect on the machine, but the ladder (the
# store, then the recipe default) governs the next reconfigure. One
# event-backed transition per record, under the host lock; a named error when
# a requested var is not a user value anywhere.
cloudify_deployment_unset() {
    local id="${1:-}" pkg="${2:-}"
    [[ -n "$id" && -n "$pkg" && $# -ge 3 ]] ||
        die "Usage: cloudify deployment unset <app>/<flavor>/<name> <package> <VAR>..."
    shift 2
    local -a vars=("$@")
    local tuple app flavor name
    tuple=$(_cloudify_deployment_tuple_of "$id") ||
        die "unset: cannot resolve the deployment '$id' (use cloudify app run <application>, or the three exports)."
    IFS=$'\t' read -r app flavor name <<< "$tuple"
    cloudify_manifest_exists "$app" "$flavor" "$name" ||
        die "unset: no manifest for $app/$flavor/$name."
    local commit dev
    commit=$(cloudify_manifest_field "$app" "$flavor" "$name" application_commit) || commit=""
    [[ "$commit" == "null" ]] && commit=""
    dev=$(cloudify_manifest_field "$app" "$flavor" "$name" development_override) || dev=false

    local bf bline slot node instance rest root rec
    local -A released=()
    bf=$(mktemp "$CLOUDIFY_TMP/unset-bindings-XXXXXX")
    cloudify_manifest_bindings "$app" "$flavor" "$name" > "$bf" ||
        { rm -f "$bf"; die "unset: no hosts bound to $app/$flavor/$name."; }
    while IFS= read -r bline; do
        [[ -n "$bline" ]] || continue
        slot="${bline%%$'\t'*}"
        rest="${bline#*$'\t'}"          # address TAB node TAB instance TAB ssh
        rest="${rest#*$'\t'}"           # skip the address field
        node="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        instance="${rest%%$'\t'*}"
        root=$(cloudify_state_inventory_root "$node" "$instance")
        cloudify_state_host_lock "$node" "$instance"
        while IFS= read -r rec; do
            [[ -f "$rec" ]] || continue
            local -a hits=()
            local v vname
            for vname in "${vars[@]}"; do
                v=$(jq -c --arg k "$vname" '.applied.values[$k] // empty' "$rec" 2>/dev/null) || continue
                [[ -n "$v" ]] || continue
                [[ "$(jq -r .source <<<"$v")" == caller ]] && hits+=("$vname")
            done
            (( ${#hits[@]} > 0 )) || continue
            local pkgname instname
            pkgname="$(basename "$(dirname "$(dirname "$rec")")")"
            instname="$(basename "$(dirname "$rec")")"
            _cloudify_deployment_unset_record "$rec" "$app" "$flavor" "$name" \
                "$pkgname" "$instname" "$node" "$instance" "$commit" "$dev" "${hits[@]}" \
                || { cloudify_state_host_unlock "$node" "$instance"; return 1; }
            for vname in "${hits[@]}"; do released[$vname]=1; done
        done < <(find "$root/$app/$flavor/$name/packages/$pkg" -mindepth 2 -maxdepth 2 -name state.json 2>/dev/null | sort)
        cloudify_state_host_unlock "$node" "$instance"
    done < "$bf"
    rm -f "$bf"

    local -a missed=()
    local vname
    for vname in "${vars[@]}"; do
        [[ -n "${released[$vname]+x}" ]] || missed+=("$vname")
    done
    if (( ${#missed[@]} > 0 )); then
        local joined=""
        for vname in "${missed[@]}"; do joined+="${joined:+, }$vname"; done
        die "unset: not user values anywhere in $app/$flavor/$name/$pkg: $joined (a user value is one you supplied at apply time - USER on the show screen)."
    fi
    for vname in "${vars[@]}"; do
        msg "unset: $vname released - the store (or the recipe default) governs the next reconfigure."
    done
    return 0
}

# _cloudify_deployment_unset_record <record> <app> <flavor> <name> <pkg>
#   <instance> <node> <inst> <commit> <dev> <VAR>...
# One event-backed transition: the named values lose the caller pin
# (source -> applied); the value text itself is untouched.
_cloudify_deployment_unset_record() {
    local rec="$1" app="$2" flavor="$3" name="$4" pkg="$5" inst="$6"
    local node="$7" ninst="$8" commit="$9" dev="${10}"
    shift 10
    local -a names=("$@")
    local joined="" n
    for n in "${names[@]}"; do joined+="${joined:+, }$n"; done

    local names_json next values
    names_json=$(printf '%s\n' "${names[@]}" | jq -R . | jq -s .)
    next=$(jq --argjson names "$names_json" '
        reduce $names[] as $k (. ; .applied.values[$k].source = "applied")' "$rec") || return 1
    values=$(jq --argjson names "$names_json" '
        .applied.values as $vs
        | reduce $names[] as $k ({} ; .[$k] = ($vs[$k]
            | {source: "applied", secret, declaration, reference, digest}
            | . + (if .secret then {} else {source_form: $vs[$k].source_form} end)))' "$rec") || return 1

    local ev ev_file next_file
    ev=$(jq -cn \
        --arg tool_version "$(cloudify_state_writer_identity | jq -r .tool_version)" \
        --argjson writer "$(cloudify_state_writer_identity | jq -c 'del(.tool_version)')" \
        --arg app "$app" --arg flavor "$flavor" --arg name "$name" \
        --arg commit "$commit" --argjson dev "$dev" \
        --arg host "${node}${ninst:+:$ninst}" \
        --arg host_key "$(cloudify_state_host_key_of "$node" "$ninst")" \
        --arg pkg "$pkg" --arg inst "$inst" \
        --argjson values "$values" \
        --arg summary "unset $joined: caller pin(s) released" \
        --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '{schema_version: 1, tool: "cloudify", tool_version: $tool_version, writer: $writer,
          at: $now, run_id: null, step_id: "unset",
          application: $app, flavor: $flavor, deployment: $name,
          application_commit: (if $commit == "" then null else $commit end),
          subject: {kind: "package", host: $host, host_key: $host_key,
                    package: $pkg, package_instance: $inst},
          phase: null, command_kind: "unset", values: $values,
          outcome: {exit_status: 0, summary: $summary}}
        | . + (if $dev then {development_override: true} else {} end)') || return 1

    mkdir -p "$(dirname "$rec")"
    ev_file=$(mktemp "$(dirname "$rec")/.unset-ev-XXXXXX") || return 1
    next_file=$(mktemp "$(dirname "$rec")/.unset-next-XXXXXX") || { rm -f "$ev_file"; return 1; }
    chmod 600 "$ev_file" "$next_file" 2>/dev/null || true
    printf '%s\n' "$ev" > "$ev_file"
    printf '%s\n' "$next" > "$next_file"
    cloudify_state_inventory_apply "$rec" "$ev_file" "$next_file" || {
        rm -f "$ev_file" "$next_file"
        return 1
    }
    rm -f "$ev_file" "$next_file"
    return 0
}
