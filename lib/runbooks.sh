#!/usr/bin/env bash
# lib/runbooks.sh — playable runbooks (Branch 7 T6a)
#
# A runbook is repo-tracked Markdown: structure + names only, never values.
# Front-matter declares the deployment and its named targets; each fenced
# ```bash step=<type> ...``` block is one step. T6a parses, discovers, binds
# targets, preflights required vars and previews (`--dry-run`). T6b executes the
# steps (`cloudify_runbook_execute`): run-wide exports, step outputs, the human
# gate and the run snapshot. T6c replays a recorded run
# (`cloudify_deployment_replay`): seed the environment from a run snapshot (target
# bindings + resolved values), then run the same engine.
#
# Machine contract (tab-separated, stable):
#   cloudify_runbook_parse <path>            one line per step:
#                                            type \t id \t target \t pkg \t body-b64 \t phase
#   cloudify_runbook_meta <path>             deployment \t targets-csv
#   cloudify_runbook_identity <path>         application \t flavor (canonical path only)
#   cloudify_runbook_inputs <path>           one declared application input name per line
#   cloudify_runbook_map <path>              one PACKAGE_VAR \t APPLICATION_INPUT per line
#   cloudify_runbook_find <id> [root]        path of the single matching runbook
#   cloudify_runbook_find_app <app> [flavor] canonical path
#   cloudify_runbook_bind_targets <path> [--target name=addr]...
#                                            name \t node \t instance \t ssh_host
#   cloudify_runbook_preflight <path> [--target name=addr]... [--phase <phase>]...
#   cloudify_runbook_execute <path> [--target name=addr]... [--from <id>] [--yes] [--phase <phase>]...
#   cloudify_deployment_run <id> [--runbook <path>] [--target name=addr]...
#                               [--from <id>] [--phase <phase>]... [--dry-run] [--yes]
#                               [--migrate-targets]
#   cloudify_deployment_replay <id> [--at <run>] [--runbook <path>]
#                               [--target name=addr]... [--from <id>] [--dry-run] [--yes]
#   cloudify_runbook_tuple_for <path> [<name>]  application \t flavor \t deployment name
#   cloudify_app_run <application>[/<flavor>] [--name <name>] [run args...]
#   cloudify_app_reserved <verb>                the Phase 4 reservation message
#
# Application runbooks live at runbooks/<application>/<flavor>/runbook.md and
# derive their identity from the path. There is no other discoverable path.
#
# Application inputs (frozen syntax): front-matter `inputs: NAME[, NAME...]`
# declares application input names and `map: PACKAGE_VAR=APPLICATION_INPUT[, ...]`
# maps package variable names onto them. Both sides are validated against
# schemas/v1/identity.md before any step runs, and a mapping input must be
# declared. `_cloudify_runbook_export_app_spec` resolves each input
# (application default < deployment value < caller env), exports the values and
# the names-only CLOUDIFY_APP_MAP for child dispatches (see runbooks/README.md).
#
# Phases: `phase=install|reconfigure|verify|teardown` is accepted on any step;
# the default is install for launch/install, reconfigure for configure, verify
# for verify and teardown for uninstall. `run` and `human-gate` have no default
# and must declare a phase. A bare run selects install then verify. `--yes`
# never selects teardown.
#
# cloudify_runbook_execute also honours CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES (a run
# snapshot path): the new snapshot records that file's `value.*` lines instead of
# the deployment store's current state. replay sets it so its own snapshot stays
# replayable after the store changes. Otherwise the snapshot keeps every
# deployment-store key and corrects/adds the declared names of the run's step
# packages with the source form the payload would use (one resolution built once
# per run). Snapshots are
# ${CLOUDIFY_DEPLOYMENTS_DIR}/<id>/runs/<utc>.yaml (0600, atomic); a name already
# taken (a run and its immediate replay share a second) gets a -2, -3, ... suffix.
#
# body-b64 is base64 so a multi-line shell body survives one line.  Empty fields
# print as empty (never omitted): a human-gate step has no target and no pkg.
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_RUNBOOKS_LOADED:-}" ]] && return 0
_CLOUDIFY_RUNBOOKS_LOADED=1

# The deployment manifest and the state root (lib/state.sh) are part of every
# application-shaped run: the manifest is created under its lock before the
# first mutating step, and its status follows the run.
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh"

_CLOUDIFY_RUNBOOK_TYPES=(launch install configure verify uninstall run human-gate)
# Step types that consume a package (and so declare required vars)
_CLOUDIFY_RUNBOOK_PKG_TYPES=(install configure verify uninstall)
# The application phases, in execution order. A selected-phase run preserves
# document order inside each phase and runs the phases in this order.
_CLOUDIFY_RUNBOOK_PHASES=(install reconfigure verify teardown)

#== Internals ==

# _cloudify_runbook_root — the runbooks tree, resolved like `pkg/`
# (${CLOUDIFY_DIR}/runbooks). CLOUDIFY_RUNBOOKS_DIR overrides it for tests.
function _cloudify_runbook_root() {
    printf '%s\n' "${CLOUDIFY_RUNBOOKS_DIR:-${CLOUDIFY_DIR:-$HOME/cloudify}/runbooks}"
}

# _cloudify_runbook_type_known <type>
function _cloudify_runbook_type_known() {
    local type="${1:-}" k
    for k in "${_CLOUDIFY_RUNBOOK_TYPES[@]}"; do
        [[ "$type" == "$k" ]] && return 0
    done
    return 1
}

# _cloudify_runbook_phase_known <phase>
function _cloudify_runbook_phase_known() {
    local phase="${1:-}" p
    for p in "${_CLOUDIFY_RUNBOOK_PHASES[@]}"; do
        [[ "$phase" == "$p" ]] && return 0
    done
    return 1
}

# _cloudify_runbook_phase_default_of <type> - the documented default phase for a
# typed step; rc 1 for run/human-gate, which have no default.
function _cloudify_runbook_phase_default_of() {
    case "${1:-}" in
        launch | install) printf 'install\n' ;;
        configure) printf 'reconfigure\n' ;;
        verify) printf 'verify\n' ;;
        uninstall) printf 'teardown\n' ;;
        *) return 1 ;;
    esac
}

# cloudify_runbook_phase_default - the canonical bare-run phase set (install
# then verify). Never includes teardown.
function cloudify_runbook_phase_default() {
    printf 'install\nverify\n'
}

# _cloudify_runbook_pkg_type <type>
function _cloudify_runbook_pkg_type() {
    local type="${1:-}" k
    for k in "${_CLOUDIFY_RUNBOOK_PKG_TYPES[@]}"; do
        [[ "$type" == "$k" ]] && return 0
    done
    return 1
}

# _cloudify_runbook_source_label <name> <pkg> - the dispatcher's single label
# implementation (lib/context.sh:cloudify_context_source_of) when the resolver
# module is loaded, else the same implementation through its lib/vars.sh
# wrapper (a unit test that loads neither). Both delegate to
# lib/vars.sh:_cloudify_vars_source_label, so preflight and dispatch cannot
# select different sources. The wrapper's display spelling (`env`) is normalized
# to the canonical one (`environment`) here: the selection is identical either
# way, and `_cloudify_vars_source_of` keeps its own spelling for display.
function _cloudify_runbook_source_label() {
    local label
    if declare -F cloudify_context_source_of >/dev/null 2>&1; then
        cloudify_context_source_of "${1:-}" "${2:-}"
        return 0
    fi
    label=$(_cloudify_vars_source_of "${1:-}" "${2:-}")
    case "$label" in
        env) printf '%s\n' environment ;;
        *) printf '%s\n' "$label" ;;
    esac
}

# _cloudify_runbook_declared_names <pkg> - declared names from
# pkg/<pkg>/.remote-vars, declaration order, one per line. The shapes live in the
# one enumerator (lib/vars.sh:cloudify_vars_declared_names).
function _cloudify_runbook_declared_names() {
    local pkg="${1:-}" name kind
    [[ -n "$pkg" ]] || return 0
    while IFS=$'\t' read -r name kind _; do
        [[ -n "$name" ]] || continue
        printf '%s\n' "$name"
    done < <(cloudify_vars_declared_names "$pkg")
}

# _cloudify_runbook_pkg_context <action> <deployment> <phase> <pkg> - resolve one
# package once and print the path of the dispatch context holding the result.
# The snapshot resolver reads each raw value from that context instead of
# reopening the store, so the snapshot and the payload cannot disagree.
# Fails closed: an unresolvable context is a broken run, not a missing value.
function _cloudify_runbook_pkg_context() {
    local action="${1:-}" deployment="${2:-}" phase="${3:-}" pkg="${4:-}" \
        file cand
    [[ -n "$pkg" ]] || return 1
    local _ctx_dir="${CLOUDIFY_CONTEXT_DIR:-$CLOUDIFY_TMP}"
    mkdir -p "$_ctx_dir" 2>/dev/null || true
    file=$(mktemp "$_ctx_dir/cloudify-runbook-context-XXXXXX") || return 1
    chmod 600 "$file" 2>/dev/null || true
    cand=$(mktemp "$CLOUDIFY_TMP/cloudify-runbook-candidates-XXXXXX") || { rm -f "$file"; return 1; }
    cloudify_context_candidate_names "$pkg" > "$cand" 2>/dev/null || true
    # Subshell: the resolved values are exported for the walk, and must not leak
    # into this shell. Only the context file matters here.
    if ! ( CLOUDIFY_CONTEXT_FILE="$file" \
        cloudify_context_build "$action" "$deployment" "$phase" "$cand" "$pkg" ) >/dev/null; then
        rm -f "$cand" "$file"
        return 1
    fi
    rm -f "$cand"
    printf '%s\n' "$file"
    return 0
}

# _cloudify_runbook_resolver_value <name> <label> <pkg> <context> - the raw,
# replayable form of the resolved value, i.e. the form the payload would use.
# The caller-env and application labels come from this shell; a store-backed
# label (deployment, package, global) reads the raw form the resolution recorded
# in the context, never the store again. A value a flat `KEY: value` line cannot
# carry verbatim (a newline, or an env literal a replay would re-read as a
# reference) is encoded as `@base64:`, the var-store encoding replay resolves.
# rc 1 when the label names no source.
function _cloudify_runbook_resolver_value() {
    local name="$1" label="$2" pkg="$3" context="${4:-}" value="" _input _enc
    case "$label" in
        environment) value="${!name:-}" ;;
        application)
            # The app input value the engine resolved into the step environment.
            _input=$(_cloudify_vars_app_input_for "$name")
            [[ -n "$_input" ]] || return 1
            value="${!_input:-}"
            ;;
        deployment | package | global)
            [[ -n "$context" && -r "$context" ]] || return 1
            _enc=$(cloudify_context_read "$context" "value.$name.raw") || return 1
            [[ -n "$_enc" ]] || return 1
            value=$(_cloudify_vars_raw_decode "$_enc") || return 1
            ;;
        *) return 1 ;;
    esac
    if [[ ( "$label" == "environment" || "$label" == "application" ) && ( "$value" == *$'\n'* || "$value" == @* ) ]]; then
        value="@base64:$(printf '%s' "$value" | base64 -w0)"
    fi
    printf '%s' "$value"
}

# cloudify_runbook_identity <path> - "application\tflavor" derived from the
# canonical path, or rc 1 when the path is not canonical. Dies (fail closed) on a
# path component the identity rules reject.
function cloudify_runbook_identity() {
    local path="${1:-}" app flavor
    [[ -n "$path" && "$path" == */runbook.md ]] || return 1
    [[ "$path" == */*/*/* ]] || return 1
    flavor="${path%/*}"; flavor="${flavor##*/}"
    app="${path%/*}"; app="${app%/*}"; app="${app##*/}"
    [[ -n "$app" && -n "$flavor" ]] || return 1
    _cloudify_identity_check_component "runbook application" "$app"
    _cloudify_identity_check_component "runbook flavor" "$flavor"
    printf '%s\t%s\n' "$app" "$flavor"
}

# _cloudify_runbook_fm_value <path> <key> - the trimmed front-matter value of one
# key, or empty. Front-matter keys are flat `key: value` lines.
function _cloudify_runbook_fm_value() {
    local path="${1:-}" key="${2:-}" fm line k
    fm=$(_cloudify_runbook_frontmatter "$path") || return 0
    while IFS= read -r line; do
        [[ "$line" == *:* ]] || continue
        k="$(_cloudify_vars_trim "${line%%:*}")"
        [[ "$k" == "$key" ]] || continue
        printf '%s' "$(_cloudify_vars_trim "${line#*:}")"
        return 0
    done <<< "$fm"
    return 0
}

# cloudify_runbook_inputs <path> - one declared application input name per line,
# deduplicated, declaration order. Every name is validated against the identity
# component rules and the variable-name shape.
function cloudify_runbook_inputs() {
    local path="${1:-}" raw name seen=""
    [[ -n "$path" ]] || return 0
    raw=$(_cloudify_runbook_fm_value "$path" inputs)
    local -a parts=()
    IFS=', ' read -ra parts <<< "$raw" || true
    for name in ${parts[@]+"${parts[@]}"}; do
        name="$(_cloudify_vars_trim "$name")"
        [[ -n "$name" ]] || continue
        [[ ",$seen," == *",$name,"* ]] && continue
        _cloudify_identity_check_component "application input" "$name"
        _cloudify_identity_check_name "application input" "$name"
        seen="${seen:+$seen,}$name"
        printf '%s\n' "$name"
    done
    return 0
}

# cloudify_runbook_map <path> - one "PACKAGE_VAR\tAPPLICATION_INPUT" per mapping
# entry (frozen `map: PACKAGE_VAR=APPLICATION_INPUT[, ...]` syntax), both sides
# validated. Declaration order preserved.
function cloudify_runbook_map() {
    local path="${1:-}" raw pair pkg input
    [[ -n "$path" ]] || return 0
    raw=$(_cloudify_runbook_fm_value "$path" map)
    local -a parts=()
    IFS=', ' read -ra parts <<< "$raw" || true
    for pair in ${parts[@]+"${parts[@]}"}; do
        pair="$(_cloudify_vars_trim "$pair")"
        [[ -n "$pair" ]] || continue
        [[ "$pair" == *=* ]] ||
            die "Runbook '$path': map entry '$pair' is not PACKAGE_VAR=APPLICATION_INPUT."
        pkg="$(_cloudify_vars_trim "${pair%%=*}")"
        input="$(_cloudify_vars_trim "${pair#*=}")"
        [[ -n "$pkg" && -n "$input" ]] ||
            die "Runbook '$path': map entry '$pair' has an empty side."
        _cloudify_identity_check_component "mapped package variable" "$pkg"
        _cloudify_identity_check_name "mapped package variable" "$pkg"
        _cloudify_identity_check_component "mapped application input" "$input"
        _cloudify_identity_check_name "mapped application input" "$input"
        printf '%s\t%s\n' "$pkg" "$input"
    done
    return 0
}

# _cloudify_runbook_export_app_spec <path> <deployment>
# Validate the application input declarations and the mapping (a mapping input
# must be declared), export CLOUDIFY_APPLICATION / CLOUDIFY_FLAVOR and the
# names-only CLOUDIFY_APP_MAP, then resolve every declared input
# (application default < deployment value < caller env) and export its value so
# a step (and its child dispatch) sees application inputs by contract. Values are
# never printed. This runs before any step.
function _cloudify_runbook_export_app_spec() {
    local path="${1:-}" deployment="${2:-}" identity app="" flavor=""
    if identity=$(cloudify_runbook_identity "$path"); then
        app="${identity%%$'\t'*}"
        flavor="${identity#*$'\t'}"
    fi
    # The path is the identity. A path that is not canonical carries none, so an
    # explicit application reference already exported by `cloudify app run`
    # (which stated the application and flavor) stays in place instead of being
    # clobbered with an empty tuple.
    if [[ -n "$app" ]]; then
        export CLOUDIFY_APPLICATION="$app"
        export CLOUDIFY_FLAVOR="$flavor"
    fi

    local -a inputs=()
    local name inputs_out
    inputs_out=$(cloudify_runbook_inputs "$path") || return 1
    while IFS= read -r name; do
        [[ -n "$name" ]] && inputs+=("$name")
    done <<< "$inputs_out"

    # Validate the mapping before exporting anything. The map is captured first:
    # a `die` inside a process substitution would otherwise be swallowed.
    local map="" pkg input found map_out
    map_out=$(cloudify_runbook_map "$path") || return 1
    local -a map_pkgs=() map_inputs=()
    while IFS=$'\t' read -r pkg input; do
        [[ -n "$pkg" ]] || continue
        map_pkgs+=("$pkg")
        map_inputs+=("$input")
    done <<< "$map_out"
    local idx
    for ((idx = 0; idx < ${#map_pkgs[@]}; idx++)); do
        pkg="${map_pkgs[idx]}"
        input="${map_inputs[idx]}"
        found=0
        for name in ${inputs[@]+"${inputs[@]}"}; do
            [[ "$name" == "$input" ]] && found=1
        done
        ((found)) ||
            die "Runbook '$path': mapping input '$input' is not declared in the front-matter 'inputs:'."
        map="${map:+$map,}$pkg=$input"
    done
    export CLOUDIFY_APP_MAP="$map"

    local raw src dep def value
    for name in ${inputs[@]+"${inputs[@]}"}; do
        raw=""; src=""
        if [[ -n "${!name:-}" ]]; then
            raw="${!name}"; src="env"
        else
            dep=""
            [[ -n "$deployment" ]] &&
                dep=$(_cloudify_vars_store_get "$(_cloudify_deployment_config || true)" "$name")
            def=""
            [[ -n "$app" && -n "$flavor" ]] &&
                def=$(_cloudify_vars_store_get "$(cloudify_vars_app_file "$app" "$flavor")" "$name")
            if [[ -n "$dep" ]]; then
                raw="$dep"; src="file"
            elif [[ -n "$def" ]]; then
                raw="$def"; src="file"
            fi
        fi
        [[ -n "$src" ]] || continue
        if [[ "$src" == "env" ]]; then
            value="$raw"
        else
            value=$(_cloudify_resolve_var_value "$name" "$raw") ||
                die "Runbook '$path': application input $name cannot be resolved."
        fi
        export "$name=$value"
    done
    return 0
}

# cloudify_runbook_phases_for <path> [<phase>...] - the phases a run selects.
# Explicit phases win (validated). With none, a run selects install then verify
# (a bare run). Teardown is never selected by a bare run, so `--yes` cannot
# reach it.
function cloudify_runbook_phases_for() {
    local p
    shift || true
    if [[ $# -gt 0 ]]; then
        for p in "$@"; do
            _cloudify_runbook_phase_known "$p" ||
                die "runbook: unknown phase '$p' (expected: ${_CLOUDIFY_RUNBOOK_PHASES[*]})."
            printf '%s\n' "$p"
        done
        return 0
    fi
    printf 'install\nverify\n'
}

# _cloudify_runbook_select_steps <path> <parse-out> [<phase>...] - the steps a
# run executes: the selected phases in canonical order, document order preserved
# inside each phase.
function _cloudify_runbook_select_steps() {
    local path="${1:-}" parse_out="${2:-}"
    shift 2 || true
    local -a phases=()
    local p phases_out
    # Capture first: a `die` inside a process substitution would be swallowed.
    phases_out=$(cloudify_runbook_phases_for "$path" "$@") || return 1
    while IFS= read -r p; do [[ -n "$p" ]] && phases+=("$p"); done <<< "$phases_out"
    local phase
    for phase in "${_CLOUDIFY_RUNBOOK_PHASES[@]}"; do
        for p in ${phases[@]+"${phases[@]}"}; do
            [[ "$p" == "$phase" ]] || continue
            awk -F'\t' -v want="$phase" 'NF && $6 == want' <<< "$parse_out"
            break
        done
    done
    return 0
}

# cloudify_runbook_phase_of <path> <step-id> - print the resolved phase of one
# step. Pure read of the parse output.
function cloudify_runbook_phase_of() {
    local path="${1:-}" id="${2:-}"
    [[ -n "$path" && -n "$id" ]] || die "Usage: cloudify_runbook_phase_of <path> <step-id>"
    cloudify_runbook_parse "$path" |
        awk -F'\t' -v want="$id" 'NF && $2 == want { print $6; found = 1 } END { exit !found }'
}

# _cloudify_runbook_now — UTC ISO8601, second precision (snapshot timestamps)
function _cloudify_runbook_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# _cloudify_runbook_utc — UTC, filename-safe (run snapshot name)
function _cloudify_runbook_utc() {
    date -u +%Y%m%dT%H%M%SZ
}

# _cloudify_runbook_target_addr <node> <instance> <ssh_host>
# Reconstruct the address `--on` accepts from a resolved binding: "node:instance",
# "node", or the plain ssh host when there is no node. This is what a step sees
# as TARGET_<NAME> and what the snapshot records as target.<name>.
function _cloudify_runbook_target_addr() {
    local node="${1:-}" instance="${2:-}" ssh_host="${3:-}" addr
    addr="${node:-$ssh_host}"
    [[ -n "$instance" ]] && addr="$addr:$instance"
    printf '%s' "$addr"
}

# _cloudify_runbook_snapshot <status> <started> <finished> <runbook> \
#                              <targets-var> <values-var> <outputs-var> \
#                              <output-order-var>
# Print the flat run snapshot on stdout. Arrays are passed by name.
function _cloudify_runbook_snapshot() {
    local status="$1" started="$2" finished="$3" runbook="$4"
    local -n _targets="$5"
    local -n _values="$6"
    local -n _outputs="$7"
    local -n _order="$8"
    printf 'status: %s\n' "$status"
    printf 'started_at: %s\n' "$started"
    printf 'finished_at: %s\n' "$finished"
    printf 'runbook: %s\n' "$runbook"
    local l o
    for l in ${_targets[@]+"${_targets[@]}"}; do printf '%s\n' "$l"; done
    for l in ${_values[@]+"${_values[@]}"}; do printf '%s\n' "$l"; done
    for o in ${_order[@]+"${_order[@]}"}; do
        printf 'output.%s: %s\n' "$o" "${_outputs[$o]}"
    done
}

# _cloudify_runbook_select_snapshot <deployment-id> [<at>] — print the chosen run
# snapshot path. --at matches an existing file path, a basename, or a timestamp
# prefix under the deployment's runs dir; without it, the most recently written
# (mtime, not name: a same-second replay shares the source's timestamp prefix).
# Dies on none or several matches.
function _cloudify_runbook_select_snapshot() {
    local id="$1" at="${2:-}"
    [[ -n "$id" ]] || die "Usage: _cloudify_runbook_select_snapshot <deployment-id> [<at>]"

    # An explicit path wins over the runs dir (a copied or archived snapshot).
    if [[ -n "$at" && -f "$at" ]]; then
        printf '%s\n' "$at"
        return 0
    fi

    local runs_dir="$CLOUDIFY_DEPLOYMENTS_DIR/$id/runs"
    [[ -d "$runs_dir" ]] ||
        die "deployment replay: no runs for deployment '$id' (expected '$runs_dir')."

    local -a all=()
    local f
    # Newest first by mtime: a run and its immediate replay share the timestamp
    # prefix (the replay's name gets a -2 suffix), so names alone cannot order them.
    mapfile -t all < <(ls -1t "$runs_dir"/*.yaml 2>/dev/null)
    [[ ${#all[@]} -gt 0 ]] ||
        die "deployment replay: no run snapshot for deployment '$id' under '$runs_dir'."

    if [[ -z "$at" ]]; then
        printf '%s\n' "${all[0]}"
        return 0
    fi

    local -a matches=() base
    for f in "${all[@]}"; do
        base="${f##*/}"
        [[ "$base" == "$at"* ]] && matches+=("$f")
    done
    [[ ${#matches[@]} -gt 0 ]] ||
        die "deployment replay: no run snapshot matching '$at' for deployment '$id' under '$runs_dir'."
    [[ ${#matches[@]} -eq 1 ]] ||
        die "deployment replay: --at '$at' is ambiguous, ${#matches[@]} runs match:"$'\n'"$(printf '  %s\n' "${matches[@]}")"
    printf '%s\n' "${matches[0]}"
}

# _cloudify_runbook_frontmatter <path> — print the front-matter body (the lines
# between the first two `---`), rc 1 when the file has none.
function _cloudify_runbook_frontmatter() {
    local path="${1:-}" line opened=false
    [[ -f "$path" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if ! $opened; then
            [[ "$line" == "---" ]] || return 1
            opened=true
            continue
        fi
        [[ "$line" == "---" ]] && return 0
        printf '%s\n' "$line"
    done < "$path"
    return 1
}

# _cloudify_runbook_meta_parse <path> — print "deployment\ttargets-csv".
# Targets may be comma- or space-separated in the source; the CSV is always
# comma-separated, deduplicated, in declaration order.
function _cloudify_runbook_meta_parse() {
    local path="${1:-}" deployment targets_raw
    _cloudify_runbook_frontmatter "$path" >/dev/null ||
        die "Runbook '$path': missing front-matter (expected the opening '---' and a closing '---')."
    deployment=$(_cloudify_runbook_fm_value "$path" deployment)
    targets_raw=$(_cloudify_runbook_fm_value "$path" targets)
    if [[ -z "$deployment" ]]; then
        # `deployment:` is optional: the caller environment may name it (an
        # application run exports it).
        deployment="${CLOUDIFY_DEPLOYMENT:-}"
        [[ -n "$deployment" ]] ||
            die "Runbook '$path': no 'deployment:' front-matter and CLOUDIFY_DEPLOYMENT is not set."
    fi

    local -a targets=()
    local -a parts=()
    IFS=', ' read -ra parts <<< "$targets_raw" || true
    local p seen=""
    for p in ${parts[@]+"${parts[@]}"}; do
        p="$(_cloudify_vars_trim "$p")"
        [[ -n "$p" ]] || continue
        [[ ",$seen," == *",$p,"* ]] && continue
        seen="${seen:+$seen,}$p"
        targets+=("$p")
    done
    local csv=""
    if [[ ${#targets[@]} -gt 0 ]]; then
        csv=$(
            IFS=,
            printf '%s' "${targets[*]}"
        )
    fi
    printf '%s\t%s\n' "$deployment" "$csv"
}

# _cloudify_runbook_deployment_of <path> — front-matter deployment id, or empty.
# One reader with _cloudify_runbook_meta_parse: the same first-match key reader.
function _cloudify_runbook_deployment_of() {
    _cloudify_runbook_fm_value "${1:-}" deployment
}

# _cloudify_runbook_emit_step <path> <line> <info> <body> <index> <declared-ref> \
#                               <seen-ref>
# Validate one fenced block. A non-step fence (info not "bash step=...") is
# silently ignored. A step prints "type\tid\ttarget\tpkg\tbody-b64", or dies
# with the runbook path + the fence's line number.
function _cloudify_runbook_emit_step() {
    local path="$1" line="$2" info="$3" body="$4" index="$5"
    local -n _declared="$6"
    local -n _seen="$7"

    local -a tokens=()
    IFS=$' \t\n' read -ra tokens <<< "$info" || true
    [[ "${tokens[0]:-}" == "bash" && "${tokens[1]:-}" == step=* ]] || return 0

    local type="${tokens[1]#step=}"
    _cloudify_runbook_type_known "$type" ||
        die "Runbook '$path': line $line: unknown step type '$type' (expected: ${_CLOUDIFY_RUNBOOK_TYPES[*]})."

    local target="" pkg="" id="" declared_phase="" tok i
    for ((i = 2; i < ${#tokens[@]}; i++)); do
        tok="${tokens[i]}"
        case "$tok" in
            target=*) target="${tok#target=}" ;;
            pkg=*) pkg="${tok#pkg=}" ;;
            id=*) id="${tok#id=}" ;;
            phase=*) declared_phase="${tok#phase=}" ;;
            *) die "Runbook '$path': line $line: unknown step attribute '$tok'." ;;
        esac
    done

    # A human gate is prose and `run` is a generic passthrough; every other step
    # addresses a target.
    if [[ "$type" != "human-gate" && "$type" != "run" && -z "$target" ]]; then
        die "Runbook '$path': line $line: step '$type' is missing 'target='."
    fi
    if _cloudify_runbook_pkg_type "$type" && [[ -z "$pkg" ]]; then
        die "Runbook '$path': line $line: step '$type' is missing 'pkg='."
    fi
    if [[ -n "$target" && -z "${_declared[$target]:-}" ]]; then
        die "Runbook '$path': line $line: target '$target' is not declared in the front-matter 'targets:'."
    fi

    # Phase: the declared phase, else the type's default. Unknown phases and a
    # typed step whose explicit phase contradicts its own operation are rejected
    # here, before execution. run/human-gate have no default, so they must
    # declare one.
    local phase="" default_phase=""
    if [[ -n "$declared_phase" ]]; then
        _cloudify_runbook_phase_known "$declared_phase" ||
            die "Runbook '$path': line $line: unknown phase '$declared_phase' (expected: ${_CLOUDIFY_RUNBOOK_PHASES[*]})."
    fi
    if default_phase=$(_cloudify_runbook_phase_default_of "$type"); then
        if [[ -n "$declared_phase" && "$declared_phase" != "$default_phase" ]]; then
            die "Runbook '$path': line $line: step '$type' cannot run in phase '$declared_phase' (expected '$default_phase')."
        fi
        phase="$default_phase"
    elif [[ -n "$declared_phase" ]]; then
        phase="$declared_phase"
    else
        die "Runbook '$path': line $line: step '$type' must declare phase= (install|reconfigure|verify|teardown)."
    fi

    [[ -n "$id" ]] || id=$(printf '%02d' "$index")
    _cloudify_identity_check_step_id "step id" "$id"
    [[ -z "${_seen[$id]:-}" ]] || die "Runbook '$path': line $line: duplicate step id '$id'."
    _seen["$id"]=1

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$type" "$id" "$target" "$pkg" \
        "$(printf '%s' "$body" | base64 -w0)" "$phase"
}

#== Public API ==

# cloudify_runbook_meta <path> — "deployment\ttargets-csv"
function cloudify_runbook_meta() {
    local path="${1:-}"
    [[ -n "$path" ]] || die "Usage: cloudify_runbook_meta <path>"
    _cloudify_runbook_meta_parse "$path"
}

# cloudify_runbook_app <path> — the path-derived "application\tflavor" of a
# canonical runbook; dies when the path is not canonical (whose identity is
# instead the front-matter `deployment:` field).
function cloudify_runbook_app() {
    local path="${1:-}"
    [[ -n "$path" ]] || die "Usage: cloudify_runbook_app <path>"
    cloudify_runbook_identity "$path" ||
        die "Runbook '$path' is not a canonical runbook (expected runbooks/<application>/<flavor>/runbook.md)."
}

# cloudify_runbook_parse <path> — one machine line per step.
function cloudify_runbook_parse() {
    local path="${1:-}"
    [[ -n "$path" ]] || die "Usage: cloudify_runbook_parse <path>"
    [[ -f "$path" ]] || die "Runbook '$path': file not found."

    local meta targets_csv
    meta=$(_cloudify_runbook_meta_parse "$path")
    targets_csv="${meta#*$'\t'}"
    local -a declared_list=()
    if [[ -n "$targets_csv" ]]; then
        IFS=',' read -ra declared_list <<< "$targets_csv" || true
    fi
    local -A declared=()
    local t
    # shellcheck disable=SC2034  # read through the nameref in _cloudify_runbook_emit_step
    for t in ${declared_list[@]+"${declared_list[@]}"}; do
        declared["$t"]=1
    done

    local line lineno=0 in_block=false info="" body="" open_line=0 index=0 trimmed
    # shellcheck disable=SC2034  # read through the nameref in _cloudify_runbook_emit_step
    local -A seen_ids=()
    # shellcheck disable=SC2094  # emit reads $path argument only; it never writes it
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        if ! $in_block; then
            if [[ "$trimmed" == '```'* ]]; then
                info="${trimmed:3}"
                info=$(_cloudify_vars_trim "$info")
                in_block=true
                body=""
                open_line=$lineno
            fi
            continue
        fi
        if [[ "$trimmed" == '```' ]]; then
            in_block=false
            index=$((index + 1))
            _cloudify_runbook_emit_step "$path" "$open_line" "$info" "$body" "$index" \
                declared seen_ids
            continue
        fi
        body="${body:+$body$'\n'}$line"
    done < "$path"
    $in_block && die "Runbook '$path': line $open_line: unterminated fenced block."
    return 0
}

# cloudify_runbook_find_app <application> [<flavor>] - the canonical
# runbooks/<application>/<flavor>/runbook.md, or a die.
function cloudify_runbook_find_app() {
    local app="${1:-}" flavor="${2:-default}" root canonical
    [[ -n "$app" ]] || die "Usage: cloudify_runbook_find_app <application> [<flavor>]"
    _cloudify_identity_check_component "application" "$app"
    _cloudify_identity_check_component "flavor" "$flavor"
    root=$(_cloudify_runbook_root)
    canonical="$root/$app/$flavor/runbook.md"
    [[ -f "$canonical" ]] || die "No runbook found for application '$app/$flavor' under '$root'."
    printf '%s\n' "$canonical"
}

# _cloudify_runbook_tuple_for <path> [<deployment-name>] - the application
# identity of a runbook: application \t flavor \t deployment name, derived from
# the canonical path. The deployment name defaults to `default`. Never derived
# from the front-matter `deployment:` ID, which stays an opaque run id. rc 1 when
# the path is not canonical, so a plain fixture runbook gets no manifest. A path
# component the identity rules reject dies (fail closed).
function _cloudify_runbook_tuple_for() {
    local path="${1:-}" name="${2:-default}" app="" flavor="" identity
    [[ -n "$path" ]] || return 1
    [[ -n "$name" ]] || return 1
    identity=$(cloudify_runbook_identity "$path") || return 1
    app="${identity%%$'\t'*}"
    flavor="${identity#*$'\t'}"
    _cloudify_identity_check_component "application" "$app"
    _cloudify_identity_check_component "flavor" "$flavor"
    _cloudify_identity_check_component "deployment name" "$name"
    printf '%s\t%s\t%s\n' "$app" "$flavor" "$name"
}

# _cloudify_runbook_source_commit - the commit of the runbook and recipes in
# use, plus whether it is a development override: print "dev\tcommit", dev
# first so a null commit is a trailing empty field rather than a leading one
# (a leading empty field would be eaten by `read`'s IFS handling). A dirty
# or unidentified tree dies unless CLOUDIFY_DEVELOPMENT_OVERRIDE=1 is set, in
# which case the manifest records the HEAD commit (or JSON null when there is
# none) with development_override=true and the deployment is labelled
# unreproducible. A dirty deployment is never presented as replayable.
function _cloudify_runbook_source_commit() {
    local dir="${CLOUDIFY_DIR:-}" commit dev="false"
    commit=$(cloudify_commit_of "$dir")
    if cloudify_tree_unreproducible "$dir"; then
        if [[ "${CLOUDIFY_DEVELOPMENT_OVERRIDE:-}" == "1" ]]; then
            dev="true"
            log_warn "Cloudify tree '$dir' is dirty or unidentified (commit ${commit:-none}); recording an unreproducible deployment (development override)."
        else
            die "deployment: the Cloudify tree '$dir' is dirty or its commit is unknown (commit: ${commit:-unknown}). Commit the tree, or set CLOUDIFY_DEVELOPMENT_OVERRIDE=1 to record an unreproducible deployment."
        fi
    fi
    [[ -n "$commit" || "$dev" == "true" ]] ||
        die "deployment: cannot identify the Cloudify commit at '$dir'."
    printf '%s\t%s\n' "$dev" "$commit"
}

# _cloudify_runbook_bindings_file <out-file> <bound-lines> - render the
# `cloudify_runbook_bind_targets` output (name\tnode\tinstance\tssh_host) as the
# bindings file the manifest takes: slot\taddress\tnode\tinstance\tssh_host.
function _cloudify_runbook_bindings_file() {
    local out="${1:-}" bound="${2:-}" line name node instance ssh_host addr
    : > "$out"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line%%$'\t'*}"
        line="${line#*$'\t'}"
        node="${line%%$'\t'*}"
        line="${line#*$'\t'}"
        instance="${line%%$'\t'*}"
        ssh_host="${line#*$'\t'}"
        addr=$(_cloudify_runbook_target_addr "$node" "$instance" "$ssh_host")
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$addr" "$node" "$instance" "$ssh_host" >> "$out"
    done <<< "$bound"
    chmod 600 "$out" 2>/dev/null || true
}

# _cloudify_deployment_manifest_prepare <app> <flavor> <name> <bound-lines>
#                                    <migrate-targets> [<cli-target>...]
# Create the manifest as `applying` before the first mutating step, or refresh
# it for a rerun. Reuses the recorded bindings: a recorded binding is never
# silently replaced. A caller-supplied binding that differs is a rebinding and
# needs --migrate-targets, because rebinding is a migration, not a rerun.
# While the deployment has active claims (Phase 4) only the claim-release path
# may rebind; the hook below is that gate for Phase 4.
function _cloudify_deployment_manifest_prepare() {
    local app="$1" flavor="$2" name="$3" bound="$4" migrate="${5:-0}"
    shift 5 2>/dev/null || true
    local -a cli_targets=("$@")
    local bindings_file commit_line commit dev old_slot old_addr rc=0
    local -A recorded=()

    bindings_file=$(mktemp) || die "deployment: cannot create a bindings file."
    _cloudify_runbook_bindings_file "$bindings_file" "$bound"

    if cloudify_manifest_exists "$app" "$flavor" "$name"; then
        while IFS=$'\t' read -r old_slot old_addr _ _ _; do
            [[ -n "$old_slot" ]] && recorded["$old_slot"]="$old_addr"
        done < <(cloudify_manifest_bindings "$app" "$flavor" "$name")
        local b name_only
        for b in ${cli_targets[@]+"${cli_targets[@]}"}; do
            name_only="${b%%=*}"
            [[ -n "${recorded[$name_only]:-}" ]] || continue
            [[ "${recorded[$name_only]}" == "${b#*=}" ]] && continue
            if declare -F cloudify_deployment_has_active_claims >/dev/null 2>&1 &&
                cloudify_deployment_has_active_claims "$app" "$flavor" "$name"; then
                rm -f "$bindings_file"
                die "deployment '$app/$flavor --name $name': target '$name_only' cannot be rebound while the deployment has active claims (release them first)."
            fi
            if [[ "$migrate" != "1" ]]; then
                rm -f "$bindings_file"
                die "deployment '$app/$flavor --name $name': refusing to rebind target '$name_only' from '${recorded[$name_only]}' to '${b#*=}'. Pass --migrate-targets to migrate the binding explicitly (no active claims exist yet, so this updates the manifest only)."
            fi
            log_warn "Target migration for '$app/$flavor --name $name': $name_only '${recorded[$name_only]}' -> '${b#*=}'."
        done
    fi

    commit_line=$(_cloudify_runbook_source_commit) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        rm -f "$bindings_file"
        return "$rc"
    fi
    IFS=$'\t' read -r dev commit <<< "$commit_line"
    cloudify_manifest_write "$app" "$flavor" "$name" applying "$commit" "$dev" "$bindings_file" || rc=$?
    rm -f "$bindings_file"
    [[ "$rc" -eq 0 ]] || return "$rc"
    msg "Manifest: $(cloudify_state_manifest_file "$app" "$flavor" "$name") (status applying)"
    return 0
}

# cloudify_deployment_has_active_claims <app> <flavor> <name> - the Phase 4
# reservation. Phase 3 records no claims, so the hook below is never defined and
# a rebinding is guarded only by --migrate-targets. Phase 4 defines it and every
# silent rebind then fails closed.

#== Application commands (state model v2 Phase 3) ==

# cloudify_app_run <application>[/<flavor>] [--name <name>] [run args...]
# Resolve the application reference, print it and the deployment name, export
# CLOUDIFY_APPLICATION / CLOUDIFY_FLAVOR / CLOUDIFY_DEPLOYMENT_NAME for the
# child dispatches, then run the application's runbook. A bare run selects
# install then verify; teardown is never selected.
function cloudify_app_run() {
    local ref="${1:-}" name="default" app="" flavor=""
    [[ -n "$ref" ]] ||
        die "Usage: cloudify app run <application>[/<flavor>] [--name <name>] [--target name=addr]... [--from <id>] [--phase <phase>]... [--dry-run] [--yes] [--migrate-targets]"
    shift
    local -a fwd=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                shift
                name="${1:-}"
                [[ -n "$name" ]] || die "app run $ref: --name needs a value."
                ;;
            *) fwd+=("$1") ;;
        esac
        shift
    done

    case "$ref" in
        */*/*)
            die "app run: '$ref' has more than one '/'; expected <application>/<flavor> (a three-segment form is never guessed)."
            ;;
        */*)
            app="${ref%%/*}"
            flavor="${ref#*/}"
            ;;
        *)
            app="$ref"
            flavor="default"
            ;;
    esac
    [[ -n "$app" && -n "$flavor" ]] ||
        die "app run: '$ref' is not <application>/<flavor> (both sides must be non-empty)."
    _cloudify_identity_check_component "application" "$app"
    _cloudify_identity_check_component "flavor" "$flavor"
    _cloudify_identity_check_component "deployment name" "$name"
    local where="app run $app/$flavor --name $name"

    export CLOUDIFY_APPLICATION="$app" CLOUDIFY_FLAVOR="$flavor" CLOUDIFY_DEPLOYMENT_NAME="$name"

    local runbook
    runbook=$(cloudify_runbook_find_app "$app" "$flavor") ||
        die "$where: no runbook found for application '$app/$flavor'."

    local deployment
    deployment=$(_cloudify_runbook_deployment_of "$runbook")
    if [[ -z "$deployment" ]]; then
        deployment="$app.$flavor.$name"
        log_debug "$where: runbook has no front-matter deployment id; using '$deployment' as the run id."
    fi
    export CLOUDIFY_DEPLOYMENT="$deployment"

    cloudify_deployment_run "$deployment" --runbook "$runbook" ${fwd[@]+"${fwd[@]}"}
}

# cloudify_app_reserved <verb> - reconfigure, verify and teardown are reserved
# until Phase 4 has physical package state and claims.
function cloudify_app_reserved() {
    die "cloudify app ${1:-} is not yet available: Phase 4 introduces reconfigure, verify and teardown with physical package state and claims. Use 'cloudify app run <application>[/<flavor>] [--name <name>]' for install plus verify."
}

# cloudify_runbook_find <deployment-id> [<runbooks-root>] — print the path of the
# single runbook whose front-matter declares that deployment.
function cloudify_runbook_find() {
    local id="${1:-}" root
    [[ -n "$id" ]] || die "Usage: cloudify_runbook_find <deployment-id> [<runbooks-root>]"
    root="${2:-$(_cloudify_runbook_root)}"
    [[ -d "$root" ]] || die "Runbooks root '$root' not found."

    local -a matches=()
    local f dep
    while IFS= read -r f; do
        # Only a canonical runbooks/<app>/<flavor>/runbook.md is discoverable.
        cloudify_runbook_identity "$f" >/dev/null 2>&1 || continue
        dep=$(_cloudify_runbook_deployment_of "$f")
        [[ "$dep" == "$id" ]] && matches+=("$f")
    done < <(find "$root" -type f -name 'runbook.md' | sort)
    [[ ${#matches[@]} -gt 0 ]] || die "No runbook found for deployment '$id' under '$root'."
    [[ ${#matches[@]} -eq 1 ]] ||
        die "Multiple runbooks found for deployment '$id':"$'\n'"$(printf '  %s\n' "${matches[@]}")"
    printf '%s\n' "${matches[0]}"
}

# cloudify_runbook_bind_targets <path> [--target name=addr]...
# For every declared target: the CLI binding, else the deployment-store var
# TARGET_<NAME> (uppercased). Prints "name\tnode\tinstance\tssh_host" after
# validating each address via the target resolver; dies listing every unbound
# target (and a binding for a name the runbook does not declare).
function cloudify_runbook_bind_targets() {
    local path="${1:-}"
    [[ -n "$path" ]] || die "Usage: cloudify_runbook_bind_targets <path> [--target name=addr]..."
    shift || true

    local -A bindings=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                shift
                [[ -n "${1:-}" && "$1" == *=* ]] || die "runbook: --target expects name=addr."
                bindings["${1%%=*}"]="${1#*=}"
                ;;
            *) die "runbook: unknown argument '$1'." ;;
        esac
        shift
    done

    local meta deployment targets_csv
    meta=$(_cloudify_runbook_meta_parse "$path")
    deployment="${meta%%$'\t'*}"
    targets_csv="${meta#*$'\t'}"
    local -a targets=()
    if [[ -n "$targets_csv" ]]; then
        IFS=',' read -ra targets <<< "$targets_csv" || true
    fi

    # Fail closed on a binding the runbook never declared (a typo would
    # otherwise surface only as a confusing "unbound target" for another name).
    local bname t found
    for bname in "${!bindings[@]}"; do
        found=false
        for t in ${targets[@]+"${targets[@]}"}; do
            [[ "$t" == "$bname" ]] && { found=true; break; }
        done
        $found || die "runbook '$path': --target '$bname' is not a declared target."
    done

    local name addr resolved
    local -a lines=() unbound=()
    for name in ${targets[@]+"${targets[@]}"}; do
        addr="${bindings[$name]:-}"
        if [[ -z "$addr" ]]; then
            addr=$(_cloudify_vars_store_get "$(_cloudify_deployment_config || true)" "TARGET_${name^^}")
        fi
        if [[ -z "$addr" ]]; then
            unbound+=("$name")
            continue
        fi
        # dies (fail closed) on an unknown/ambiguous address
        resolved=$(_cloudify_target_resolve "$addr")
        lines+=("$(printf '%s\t%s' "$name" "$resolved")")
    done

    if [[ ${#unbound[@]} -gt 0 ]]; then
        die "Unbound target(s) for deployment '$deployment': ${unbound[*]}. Bind with --target <name>=<addr> or set the deployment var TARGET_<NAME>."
    fi
    local l
    for l in ${lines[@]+"${lines[@]}"}; do printf '%s\n' "$l"; done
}

# cloudify_runbook_preflight <path> [--target name=addr]... [--phase <phase>]...
# Resolve every target, then check that each required name (a bare NAME line in
# pkg/<pkg>/.remote-vars) of every package step in the SELECTED phases resolves
# through the var ladder. A recipe-default source means unresolved. Dies listing
# every missing "pkg: NAME". Only selected phases are inspected, so a
# teardown-only value cannot block an install run.
function cloudify_runbook_preflight() {
    local path="${1:-}"
    [[ -n "$path" ]] || die "Usage: cloudify_runbook_preflight <path> [--target name=addr]... [--phase <phase>]..."
    shift || true

    local -a cli_phases=() bind_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --phase)
                shift
                _cloudify_runbook_phase_known "${1:-}" ||
                    die "runbook preflight: unknown phase '${1:-}' (expected: ${_CLOUDIFY_RUNBOOK_PHASES[*]})."
                cli_phases+=("$1")
                ;;
            --target)
                bind_args+=(--target "${2:-}")
                shift
                ;;
            *) die "runbook preflight: unknown argument '$1'." ;;
        esac
        shift
    done

    local meta deployment
    meta=$(_cloudify_runbook_meta_parse "$path")
    deployment="${meta%%$'\t'*}"
    # Target validation first: an unbound target is a harder failure than a var.
    cloudify_runbook_bind_targets "$path" ${bind_args[@]+"${bind_args[@]}"} > /dev/null

    # The deployment store of the runbook's own deployment is part of the ladder,
    # so source_of must see it (the router exits after the engine returns).
    export CLOUDIFY_DEPLOYMENT="$deployment"
    # The application spec must be visible to the source label (a mapped input is
    # resolved), and it is validated before any step.
    _cloudify_runbook_export_app_spec "$path" "$deployment" || return 1

    local parse_out steps_out
    parse_out=$(cloudify_runbook_parse "$path") || return 1
    steps_out=$(_cloudify_runbook_select_steps "$path" "$parse_out" ${cli_phases[@]+"${cli_phases[@]}"}) || return 1

    local -a missing=()
    local seen_missing=""
    local line type rest pkg name kind src
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        type="${line%%$'\t'*}"
        _cloudify_runbook_pkg_type "$type" || continue
        rest="${line#*$'\t'}"     # drop type -> id\ttarget\tpkg\tbody
        rest="${rest#*$'\t'}"      # drop id -> target\tpkg\tbody
        rest="${rest#*$'\t'}"      # drop target -> pkg\tbody
        pkg="${rest%%$'\t'*}"
        [[ -n "$pkg" ]] || continue
        [[ -f "$CLOUDIFY_DIR/pkg/$pkg/.remote-vars" ]] || continue
        while IFS=$'\t' read -r name kind _; do
            [[ "$kind" == "required" ]] || continue # NAME=/NAME=value are not required
            src=$(_cloudify_runbook_source_label "$name" "$pkg")
            case "$src" in
                recipe | recipe-default) ;;
                *) continue ;;
            esac
            [[ ",$seen_missing," == *",$pkg:$name,"* ]] && continue
            seen_missing="${seen_missing:+$seen_missing,}$pkg:$name"
            missing+=("$pkg: $name")
        done < <(cloudify_vars_declared_names "$pkg")
    done <<< "$steps_out"

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Runbook '$path': unresolved required vars:"$'\n'"$(printf '  %s\n' "${missing[@]}")"
    fi
}

# cloudify_deployment_run <id> [--runbook <path>] [--target name=addr]...
#                           [--from <id>] [--phase <phase>]... [--dry-run] [--yes]
#                           [--migrate-targets]
# find + parse + bind + preflight + print the plan; without --dry-run it creates
# the deployment manifest as `applying` (before the first mutating step) and
# then dispatches cloudify_runbook_execute. Phase selection is opt-in; a bare
# run selects install then verify.
function cloudify_deployment_run() {
    local id="" runbook="" from="" dry=0 yes=0 migrate_targets=0
    local -a target_bindings=() cli_targets=()
    local -a cli_phases=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --runbook)
                shift
                runbook="${1:-}"
                [[ -n "$runbook" ]] || die "deployment: --runbook needs a path."
                ;;
            --target)
                shift
                [[ -n "${1:-}" && "$1" == *=* ]] || die "deployment: --target expects name=addr."
                target_bindings+=("$1")
                cli_targets+=("$1")
                ;;
            --from)
                shift
                from="${1:-}"
                [[ -n "$from" ]] || die "deployment: --from needs a step id."
                ;;
            --phase)
                shift
                _cloudify_runbook_phase_known "${1:-}" ||
                    die "deployment: unknown phase '${1:-}' (expected: ${_CLOUDIFY_RUNBOOK_PHASES[*]})."
                cli_phases+=("$1")
                ;;
            --migrate-targets) migrate_targets=1 ;;
            --dry-run) dry=1 ;;
            --yes) yes=1 ;; # non-interactive human-gate confirmation
            -*) die "deployment: unknown flag '$1'." ;;
            *)
                [[ -z "$id" ]] || die "deployment: unexpected argument '$1'."
                id="$1"
                ;;
        esac
        shift
    done
    [[ -n "$id" ]] ||
        die "Usage: cloudify_deployment_run <id> [--runbook <path>] [--target name=addr]... [--from <id>] [--phase <phase>]... [--dry-run] [--yes] [--migrate-targets]"

    if [[ -n "$runbook" ]]; then
        [[ -f "$runbook" ]] || die "Runbook '$runbook' not found."
    else
        runbook=$(cloudify_runbook_find "$id")
    fi

    local meta deployment
    meta=$(_cloudify_runbook_meta_parse "$runbook")
    deployment="${meta%%$'\t'*}"
    [[ "$deployment" == "$id" ]] ||
        die "Runbook '$runbook' declares deployment '$deployment', not '$id'."

    # Application identity. An explicit reference exported by `cloudify app run`
    # wins; otherwise the canonical runbook path is the identity. A path with no
    # canonical shape has no identity, so no manifest is written.
    local tuple="" app="" flavor="" name="" manifest=0 b
    if tuple=$(_cloudify_runbook_tuple_for "$runbook" "${CLOUDIFY_DEPLOYMENT_NAME:-default}" 2>/dev/null); then
        IFS=$'\t' read -r app flavor name <<< "$tuple"
        export CLOUDIFY_APPLICATION="$app" CLOUDIFY_FLAVOR="$flavor" CLOUDIFY_DEPLOYMENT_NAME="$name"
        manifest=1
    fi

    # Recorded bindings: reconfigure, verify and teardown reuse them instead of
    # re-prompting. A slot the caller bound explicitly keeps the caller's value.
    if ((manifest)) && cloudify_manifest_exists "$app" "$flavor" "$name"; then
        local rslot raddr supplied
        while IFS=$'\t' read -r rslot raddr _ _ _; do
            [[ -n "$rslot" ]] || continue
            supplied=0
            for b in ${cli_targets[@]+"${cli_targets[@]}"}; do
                [[ "${b%%=*}" == "$rslot" ]] && supplied=1
            done
            ((supplied)) && continue
            target_bindings+=("$rslot=$raddr")
        done < <(cloudify_manifest_bindings "$app" "$flavor" "$name")
    fi

    local -a bind_args=()
    for b in ${target_bindings[@]+"${target_bindings[@]}"}; do
        bind_args+=(--target "$b")
    done
    local -a phase_args=()
    for b in ${cli_phases[@]+"${cli_phases[@]}"}; do
        phase_args+=(--phase "$b")
    done

    local bound parse_out steps_out
    bound=$(cloudify_runbook_bind_targets "$runbook" ${bind_args[@]+"${bind_args[@]}"}) || return 1
    cloudify_runbook_preflight "$runbook" ${bind_args[@]+"${bind_args[@]}"} ${phase_args[@]+"${phase_args[@]}"} || return 1
    parse_out=$(cloudify_runbook_parse "$runbook") || return 1
    steps_out=$(_cloudify_runbook_select_steps "$runbook" "$parse_out" ${cli_phases[@]+"${cli_phases[@]}"}) || return 1

    if [[ -n "$from" ]] &&
        ! awk -F'\t' -v want="$from" '$2 == want { found = 1 } END { exit !found }' <<< "$steps_out"; then
        die "deployment: no step with id '$from' (--from) in the selected phases."
    fi

    local selected_phases=""
    selected_phases=$(cloudify_runbook_phases_for "$runbook" ${cli_phases[@]+"${cli_phases[@]}"} | paste -sd, -)
    if ((manifest)); then
        msg "Application: $app/$flavor"
        msg "Deployment: $name"
    fi
    msg "Deployment: $deployment"
    msg "Runbook: $runbook"
    msg "Phases: $selected_phases"
    msg "Targets:"
    local name_ rest node instance ssh_host
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name_="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        node="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        instance="${rest%%$'\t'*}"
        ssh_host="${rest#*$'\t'}"
        msg "  $name_ -> node=${node:-<plain>} instance=${instance:-<none>} ssh=$ssh_host"
    done <<< "$bound"

    msg "Steps:"
    local type sid tgt pkg phase body_b64
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        type="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        sid="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        tgt="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        pkg="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        body_b64="${rest%%$'\t'*}"
        phase="${rest#*$'\t'}"
        msg "  $sid  $type${phase:+  phase=$phase}${tgt:+  target=$tgt}${pkg:+  pkg=$pkg}"
    done <<< "$steps_out"

    if [[ "$dry" == "1" ]]; then
        if ((manifest)); then
            msg "Manifest: $(cloudify_state_manifest_file "$app" "$flavor" "$name") (dry run: not created)"
        fi
        return 0
    fi

    # The manifest exists before the first mutating step, under its own lock.
    if ((manifest)); then
        _cloudify_deployment_manifest_prepare "$app" "$flavor" "$name" "$bound" "$migrate_targets" \
            ${cli_targets[@]+"${cli_targets[@]}"} || return $?
    fi

    local -a exec_args=()
    for b in ${target_bindings[@]+"${target_bindings[@]}"}; do
        exec_args+=(--target "$b")
    done
    [[ -n "$from" ]] && exec_args+=(--from "$from")
    [[ "$yes" == "1" ]] && exec_args+=(--yes)
    for b in ${cli_phases[@]+"${cli_phases[@]}"}; do
        exec_args+=(--phase "$b")
    done
    cloudify_runbook_execute "$runbook" ${exec_args[@]+"${exec_args[@]}"}
}

# cloudify_runbook_execute <path> [--target name=addr]... [--from <id>] [--yes] [--phase <phase>]...
# Execute a runbook's selected steps. Exports CLOUDIFY_DEPLOYMENT,
# TARGET_<NAME> and CLOUDIFY_OUTPUTS_FILE for the whole run; each step gets
# STEP_ID/STEP_TYPE/STEP_TARGET/STEP_PKG/STEP_PHASE. A step appends `name=value`
# to the outputs file and later steps see it as OUT_<name>. Stops at the first
# failure and always writes the run snapshot.
function cloudify_runbook_execute() {
    local path="${1:-}"
    [[ -n "$path" ]] ||
        die "Usage: cloudify_runbook_execute <path> [--target name=addr]... [--from <id>] [--yes] [--phase <phase>]..."
    shift || true

    local from="" yes=0
    local -a target_bindings=()
    local -a cli_phases=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                shift
                [[ -n "${1:-}" && "$1" == *=* ]] || die "runbook execute: --target expects name=addr."
                target_bindings+=("$1")
                ;;
            --from)
                shift
                [[ -n "${1:-}" ]] || die "runbook execute: --from needs a step id."
                from="$1"
                ;;
            --phase)
                shift
                _cloudify_runbook_phase_known "${1:-}" ||
                    die "runbook execute: unknown phase '${1:-}' (expected: ${_CLOUDIFY_RUNBOOK_PHASES[*]})."
                cli_phases+=("$1")
                ;;
            --yes) yes=1 ;;
            *) die "runbook execute: unknown argument '$1'." ;;
        esac
        shift
    done
    [[ -f "$path" ]] || die "Runbook '$path': file not found."

    local -a bind_args=()
    local b
    for b in ${target_bindings[@]+"${target_bindings[@]}"}; do
        bind_args+=(--target "$b")
    done
    local -a phase_args=()
    for b in ${cli_phases[@]+"${cli_phases[@]}"}; do
        phase_args+=(--phase "$b")
    done

    # 1. Fail before executing anything: targets resolvable, required vars present.
    cloudify_runbook_preflight "$path" ${bind_args[@]+"${bind_args[@]}"} ${phase_args[@]+"${phase_args[@]}"} || return 1

    local meta deployment bound parse_out steps_out
    meta=$(_cloudify_runbook_meta_parse "$path") || return 1
    deployment="${meta%%$'\t'*}"
    bound=$(cloudify_runbook_bind_targets "$path" ${bind_args[@]+"${bind_args[@]}"})
    parse_out=$(cloudify_runbook_parse "$path") || return 1
    # Only the selected phases run; inside a phase the document order is kept.
    steps_out=$(_cloudify_runbook_select_steps "$path" "$parse_out" ${cli_phases[@]+"${cli_phases[@]}"}) || return 1

    if [[ -n "$from" ]] &&
        ! awk -F'\t' -v want="$from" '$2 == want { found = 1 } END { exit !found }' <<< "$steps_out"; then
        die "runbook execute: no step with id '$from' (--from) in the selected phases."
    fi

    # 2. Run-wide exports: the deployment, every bound target, the outputs channel.
    export CLOUDIFY_DEPLOYMENT="$deployment"
    local line rest name node instance ssh_host addr
    local -a target_lines=()
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        node="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        instance="${rest%%$'\t'*}"
        ssh_host="${rest#*$'\t'}"
        addr=$(_cloudify_runbook_target_addr "$node" "$instance" "$ssh_host")
        export "TARGET_${name^^}=$addr"
        target_lines+=("target.$name: $addr")
    done <<< "$bound"

    local outputs_file
    outputs_file=$(mktemp) || die "runbook execute: cannot create the outputs file."
    chmod 600 "$outputs_file" 2>/dev/null || true
    export CLOUDIFY_OUTPUTS_FILE="$outputs_file"

    # 3. Snapshot the run's values for the record. A replay sets
    # CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES (its source snapshot): the new record then
    # carries the values the run was seeded with, so it stays replayable even if
    # the store changed since.
    # Without a replay the record keeps every deployment-store key it always
    # kept and corrects/adds the declared names the resolver knows, with the same
    # source form the payload would use (one resolution, design section 6.4).
    # The resolver view is built ONCE, here, never per step and never printed.
    local -a value_lines=()
    local cfg
    if [[ -n "${CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES:-}" ]]; then
        [[ -f "$CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES" ]] ||
            die "runbook execute: replayed snapshot '$CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES' not found."
        local rline
        while IFS= read -r rline; do
            [[ "$rline" == value.* ]] || continue
            value_lines+=("$rline")
        done < "$CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES"
    else
        local -a _rv_order=()
        local -A _rv_value=()
        local -A _rv_pkg=() _rv_seen=()
        local _rl _rtype _rrest _rpkg _rphase _rname _rlabel _rvalue
        while IFS= read -r _rl; do
            [[ -n "$_rl" ]] || continue
            _rtype="${_rl%%$'\t'*}"
            _cloudify_runbook_pkg_type "$_rtype" || continue
            _rrest="${_rl#*$'\t'}"     # drop type -> id\ttarget\tpkg\tbody
            _rrest="${_rrest#*$'\t'}"  # drop id -> target\tpkg\tbody
            _rrest="${_rrest#*$'\t'}"  # drop target -> pkg\tbody\tphase
            _rpkg="${_rrest%%$'\t'*}"
            _rphase="${_rrest##*$'\t'}"
            [[ -n "$_rpkg" ]] || continue
            [[ -n "${_rv_pkg[$_rpkg]:-}" ]] && continue
            _rv_pkg["$_rpkg"]=1
            # One resolution for this package, in its own context. The step's own
            # type is the action: no field is invented, and no store is read again.
            local _rctx=""
            _rctx=$(_cloudify_runbook_pkg_context "$_rtype" "$deployment" "$_rphase" "$_rpkg") \
                || die "runbook execute: cannot resolve '$_rpkg' for the run's snapshot."
            while IFS= read -r _rname; do
                [[ -n "$_rname" ]] || continue
                [[ -n "${_rv_seen[$_rname]:-}" ]] && continue
                _rv_seen["$_rname"]=1
                _rlabel=$(_cloudify_runbook_source_label "$_rname" "$_rpkg")
                case "$_rlabel" in
                    recipe | recipe-default) continue ;;
                esac
                # Fail closed. A declared name that resolves to nothing would leave
                # the snapshot silently missing a value, which is how a replay
                # ends up seeding a different run than the one that happened.
                _rvalue=$(_cloudify_runbook_resolver_value "$_rname" "$_rlabel" "$_rpkg" "$_rctx") \
                    || die "runbook execute: cannot recover a value for '$_rname' in package '$_rpkg' for the run's snapshot."
                _rv_order+=("$_rname")
                _rv_value["$_rname"]="$_rvalue"
            done < <(_cloudify_runbook_declared_names "$_rpkg")
            [[ -n "$_rctx" ]] && rm -f "$_rctx"
        done <<< "$steps_out"

        local -A _vline=() _vseen=()
        local -a _vorder=()
        # Carry forward the lines already in the deployment desired-inputs file,
        # so no existing snapshot line disappears when a later run rewrites it.
        # This is a copy of prior raw lines, not a value-resolution walk: every
        # declared name's value is resolved from the context below
        # (_cloudify_runbook_resolver_value), and that resolver view overrides
        # the carried-forward line.
        cfg=$(_cloudify_deployment_config) || cfg=""
        if [[ -f "$cfg" ]]; then
            local vline vkey
            while IFS= read -r vline; do
                [[ -n "$vline" && "$vline" != \#* && "$vline" == *:* ]] || continue
                vkey="$(_cloudify_vars_trim "${vline%%:*}")"
                [[ -n "$vkey" ]] || continue
                _vline["$vkey"]="value.$vkey: $(_cloudify_vars_trim "${vline#*:}")"
                if [[ -z "${_vseen[$vkey]:-}" ]]; then _vseen["$vkey"]=1; _vorder+=("$vkey"); fi
            done < "$cfg"
        fi
        # The resolver view corrects an existing line or appends a new one; no
        # deployment-store line ever disappears.
        local vname
        for vname in ${_rv_order[@]+"${_rv_order[@]}"}; do
            _vline["$vname"]="value.$vname: ${_rv_value[$vname]}"
            if [[ -z "${_vseen[$vname]:-}" ]]; then _vseen["$vname"]=1; _vorder+=("$vname"); fi
        done
        for vname in ${_vorder[@]+"${_vorder[@]}"}; do
            value_lines+=("${_vline[$vname]}")
        done
    fi

    # 4/5. Walk the steps, streaming their output, collecting step outputs.
    local status="succeeded" fail_msg="" started_at finished_at
    started_at=$(_cloudify_runbook_now)
    local -A run_outputs=()
    local -a run_output_order=()
    local outputs_consumed=0
    local type sid tgt pkg phase body body_b64 started=0
    local -a step_lines=()
    local line
    [[ -z "$from" ]] && started=1

    # Read the step list into an array first: a step body must not be able to
    # steal the remaining steps. They used to be fed through the loop's stdin
    # (a here-string), so any `read`/`cat` inside a body consumed the rest -
    # the run truncated, reported success, and skipped the gate and teardown.
    while IFS= read -r line; do step_lines+=("$line"); done <<< "$steps_out"
    for line in "${step_lines[@]}"; do
        [[ -n "$line" ]] || continue
        type="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        sid="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        tgt="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        pkg="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        body_b64="${rest%%$'\t'*}"
        phase="${rest#*$'\t'}"
        body=$(printf '%s' "$body_b64" | base64 -d)

        if [[ "$started" == "0" ]]; then
            [[ "$sid" == "$from" ]] || continue
            started=1
        fi

        export STEP_ID="$sid" STEP_TYPE="$type" STEP_TARGET="$tgt" STEP_PKG="$pkg" STEP_PHASE="$phase"

        if [[ "$type" == "human-gate" ]]; then
            msg "human-gate [$sid]"
            msg "$body"
            if [[ "$yes" != "1" ]]; then
                if [[ ! -t 0 ]]; then
                    status="failed"
                    fail_msg="Runbook step '$sid' (human-gate): no TTY to confirm; re-run with --yes."
                    break
                fi
                local reply=""
                if ! read -r -p "Confirm step '$sid'? [y/N] " reply || [[ ! "$reply" =~ ^[Yy] ]]; then
                    status="failed"
                    fail_msg="Runbook step '$sid' (human-gate): not confirmed."
                    break
                fi
            fi
            continue
        fi

        local rc=0
        bash -c "$body" </dev/null || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            status="failed"
            fail_msg="Runbook step '$sid' failed (exit $rc)."
        fi

        # Ingest outputs appended by this step (also on failure: keep the record).
        local oline oname oval new_count=0
        while IFS= read -r oline; do
            new_count=$((new_count + 1))
            [[ -n "$oline" && "$oline" != \#* && "$oline" == *=* ]] || continue
            oname="${oline%%=*}"
            oval="${oline#*=}"
            [[ "$oname" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            export "OUT_$oname=$oval"
            if [[ -z "${run_outputs[$oname]+x}" ]]; then
                run_output_order+=("$oname")
            fi
            run_outputs["$oname"]="$oval"
        done < <(tail -n +$((outputs_consumed + 1)) "$outputs_file")
        outputs_consumed=$((outputs_consumed + new_count))

        [[ "$status" == "failed" ]] && break
    done

    finished_at=$(_cloudify_runbook_now)

    # 6. Write the run snapshot (always, success or failure).
    local runs_dir="$CLOUDIFY_DEPLOYMENTS_DIR/$deployment/runs"
    (umask 077; mkdir -p "$runs_dir")
    chmod 700 "$runs_dir" 2>/dev/null || true
    local snapshot tmp
    snapshot="$runs_dir/$(_cloudify_runbook_utc).yaml"
    # A run and its immediate replay land in the same second: never overwrite an
    # existing snapshot, suffix -2, -3, ... instead (the source run must survive
    # a replay). `--at` still selects by timestamp prefix.
    local n=1 base="${snapshot%.yaml}"
    while [[ -e "$snapshot" ]]; do
        n=$((n + 1))
        snapshot="$base-$n.yaml"
    done
    tmp=$(mktemp "$runs_dir/.run.XXXXXX") || die "runbook execute: cannot create the run snapshot."
    _cloudify_runbook_snapshot "$status" "$started_at" "$finished_at" "$path" \
        target_lines value_lines run_outputs run_output_order > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$snapshot"

    rm -f "$outputs_file"
    unset CLOUDIFY_OUTPUTS_FILE STEP_ID STEP_TYPE STEP_TARGET STEP_PKG STEP_PHASE

    # 7. Manifest lifecycle (Phase 3). The manifest was created as `applying`
    # before the first step. A successful install plus verify from the start of
    # the run ends `active`; an observed failure ends `degraded`; anything else
    # keeps its recorded status. A killed process never reaches this code, so the
    # manifest stays `applying`, which is the discoverable interrupted state (run
    # and event records, and their stale-run classification, are Phase 6).
    if [[ -n "${CLOUDIFY_APPLICATION:-}" && -n "${CLOUDIFY_FLAVOR:-}" && -n "${CLOUDIFY_DEPLOYMENT_NAME:-}" ]] \
        && cloudify_manifest_exists "$CLOUDIFY_APPLICATION" "$CLOUDIFY_FLAVOR" "$CLOUDIFY_DEPLOYMENT_NAME"; then
        local _commit_line _mcommit _mdev _mstatus _mapp _mflavor _mname
        _mapp="$CLOUDIFY_APPLICATION"
        _mflavor="$CLOUDIFY_FLAVOR"
        _mname="$CLOUDIFY_DEPLOYMENT_NAME"
        _commit_line=$(_cloudify_runbook_source_commit)
        IFS=$'\t' read -r _mdev _mcommit <<< "$_commit_line"
        if [[ "$status" == "failed" ]]; then
            _mstatus="degraded"
        else
            _mstatus=$(cloudify_manifest_field "$_mapp" "$_mflavor" "$_mname" status)
            # `active` means the deployment was installed AND verified. A run that
            # selected only one of the two keeps its recorded status.
            local _mphases=""
            _mphases=$(cloudify_runbook_phases_for "$path" ${cli_phases[@]+"${cli_phases[@]}"})
            if [[ -z "$from" ]] &&
                grep -qx install <<< "$_mphases" &&
                grep -qx verify <<< "$_mphases"; then
                _mstatus="active"
            fi
            [[ -n "$_mstatus" ]] || _mstatus="applying"
        fi
        cloudify_manifest_update_status "$_mapp" "$_mflavor" "$_mname" "$_mstatus" "$_mcommit" "$_mdev" ||
            return $?
        msg "Manifest: $(cloudify_state_manifest_file "$_mapp" "$_mflavor" "$_mname") (status $_mstatus)"
    fi

    if [[ "$status" == "failed" ]]; then
        die "$fail_msg"
    fi
    msg "Runbook '$path' $status."
    msg "Snapshot: $snapshot"
    return 0
}

# cloudify_deployment_replay <id> [--at <run>] [--runbook <path>] [--target name=addr]...
#                             [--from <id>] [--dry-run] [--yes]
# Re-run a recorded run. The environment is seeded from a run snapshot before
# anything executes: every `target.<name>` becomes a binding (a --target on the
# command line still wins) and every `value.<NAME>` is resolved (a stored
# @base64:/@backend: reference must be resolved here, or the step would receive
# the literal) and exported, so the normal ladder forwards exactly the recorded
# values. The runbook defaults to the snapshot's. Then the same engine as
# `deployment replay` runs (preflight + steps + a new run snapshot). Seeded values
# are referred to by name only: never printed, never part of argv.
function cloudify_deployment_replay() {
    local id="" at="" runbook="" from="" dry=0 yes=0 migrate_targets=0
    local -a cli_bindings=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --at)
                shift
                at="${1:-}"
                [[ -n "$at" ]] || die "deployment replay: --at needs a run path, basename or timestamp prefix."
                ;;
            --runbook)
                shift
                runbook="${1:-}"
                [[ -n "$runbook" ]] || die "deployment replay: --runbook needs a path."
                ;;
            --target)
                shift
                [[ -n "${1:-}" && "$1" == *=* ]] || die "deployment replay: --target expects name=addr."
                cli_bindings+=("$1")
                ;;
            --from)
                shift
                from="${1:-}"
                [[ -n "$from" ]] || die "deployment replay: --from needs a step id."
                ;;
            --dry-run) dry=1 ;;
            --yes) yes=1 ;;
            --migrate-targets) migrate_targets=1 ;;
            -*) die "deployment replay: unknown flag '$1'." ;;
            *)
                [[ -z "$id" ]] || die "deployment replay: unexpected argument '$1'."
                id="$1"
                ;;
        esac
        shift
    done
    [[ -n "$id" ]] ||
        die "Usage: cloudify deployment replay <id> [--at <run>] [--runbook <path>] [--target name=addr]... [--from <id>] [--dry-run] [--yes] [--migrate-targets]"

    local snapshot
    # The selector dies with the reason (none/ambiguous); stop here explicitly
    # rather than relying on errexit, which a caller in a || list disables.
    if ! snapshot=$(_cloudify_runbook_select_snapshot "$id" "$at"); then
        exit 1
    fi
    grep -q '^runbook:' "$snapshot" ||
        die "deployment replay: '$snapshot' is not a run snapshot (no 'runbook:' line)."

    # Command-line bindings win over the snapshot's.
    local -A cli_bound=()
    local b
    for b in ${cli_bindings[@]+"${cli_bindings[@]}"}; do
        cli_bound["${b%%=*}"]="${b#*=}"
    done

    local line key raw value snap_runbook=""
    local -a value_names=() target_args=() seeded_targets=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" && "$line" == *:* ]] || continue
        key="$(_cloudify_vars_trim "${line%%:*}")"
        raw="$(_cloudify_vars_trim "${line#*:}")"
        case "$key" in
            runbook) snap_runbook="$raw" ;;
            target.*)
                key="${key#target.}"
                [[ -n "$key" ]] || die "deployment replay: '$snapshot': empty target name."
                [[ -n "${cli_bound[$key]+x}" ]] && continue
                target_args+=(--target "$key=$raw")
                seeded_targets+=("$key=$raw")
                ;;
            value.*)
                key="${key#value.}"
                [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
                    die "deployment replay: '$snapshot': malformed value name '$key'."
                _cloudify_vars_reserved "$key" &&
                    die "deployment replay: '$snapshot' records the framework-owned var '$key' — refusing to seed it."
                # Resolve before exporting (the env path is a pass-through). The
                # value stays in this process's environment, never in output.
                value=$(_cloudify_resolve_var_value "$key" "$raw") ||
                    die "deployment replay: var $key: cannot resolve the snapshot value — refusing to replay an empty value."
                export "$key"="$value"
                value_names+=("$key")
                ;;
        esac
    done < "$snapshot"

    [[ -n "$runbook" ]] || runbook="$snap_runbook"
    [[ -f "$runbook" ]] ||
        die "deployment replay: runbook '$runbook' (from $snapshot) not found; pass --runbook <path>."

    local names_str="" targets_str=""
    [[ ${#value_names[@]} -gt 0 ]] &&
        names_str=$(IFS=','; printf '%s' "${value_names[*]}")
    [[ ${#seeded_targets[@]} -gt 0 ]] &&
        targets_str=$(IFS=','; printf '%s' "${seeded_targets[*]}")
    msg "Replay: $snapshot"
    msg "Seeded values (names only): ${names_str:-<none>}"
    msg "Seeded targets: ${targets_str:-<none>}"

    local -a run_args=()
    for b in ${cli_bindings[@]+"${cli_bindings[@]}"}; do
        run_args+=(--target "$b")
    done
    for b in ${target_args[@]+"${target_args[@]}"}; do
        run_args+=("$b")
    done
    [[ -n "$from" ]] && run_args+=(--from "$from")
    [[ "$dry" == "1" ]] && run_args+=(--dry-run)
    [[ "$yes" == "1" ]] && run_args+=(--yes)
    [[ "$migrate_targets" == "1" ]] && run_args+=(--migrate-targets)

    # The engine records the seeded values (not the store's current state) in the
    # new snapshot, so a replay stays replayable after the store changes.
    CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES="$snapshot"
    cloudify_deployment_run "$id" --runbook "$runbook" ${run_args[@]+"${run_args[@]}"}
}
