#!/usr/bin/env bash
# lib/worker.sh - the dispatch worker (state-model-v2 4.3).
#
# One worker per package dispatch, invoked by the router once the dispatch
# child finishes. Sequence (design "One host lock", "Expected results and
# reconciliation", "Commit provenance"):
#
#   1. acquire the one host mutation lock - before any scan or remote work,
#      held through collection, reconciliation, the executed-code verdict and
#      every ordered event+inventory commit;
#   2. validate the collected result lines, then reconcile them against the
#      requested words - any gap fails the dispatch before any inventory write;
#   3. the executed-code verdict - a mismatch, dirty or undeterminable
#      checkout on a proved dispatch degrades it: one event records the
#      executed commit, nothing else is written;
#   4. ordered commits from the classified lines: requested, dependency,
#      framework and unrequested lines each commit one event + one inventory
#      transition (event first); native subjects are report-only;
#   5. release the host lock BEFORE the per-deployment manifest lock - the
#      two are never held together (test-only assertion in lib/state.sh);
#   6. manifest projection: the status word comes from the SAME event-log
#      derivation a rebuild runs (GLOSSARY manifest status) - the worker
#      never decides it a second way. Install success ends installed,
#      reconfigure reconfigured, a passing verify verified; a failed attempt
#      (its line event carries the non-zero exit) or a worker failure (its
#      own degraded event) ends degraded - except a failed verify stage
#      (exit 0, verification failed), which is information, not a downgrade:
#      health records it, the completed work's word stands. A non-state-
#      relevant action keeps the recorded word.
#
# All value content comes from the ONE parsed dispatch context; the worker
# never re-resolves a value and never invents one after execution.

set -Eeuo pipefail

[[ -n "${_CLOUDIFY_WORKER_LOADED:-}" ]] && return 0
_CLOUDIFY_WORKER_LOADED=1

# The per-line commit context: set by the commit loop, read by the committer.
# (One process, one loop - module-level state, never caller-visible.)
declare -gA _WORKER_LINE=()
_WORKER_LINE_CLASS=""
_WORKER_PROJECTION=""
_WORKER_EVENT_PROJECTION=""
_WORKER_APP="" _WORKER_FLAVOR="" _WORKER_NAME=""
_WORKER_STEP=""
_WORKER_NODE="" _WORKER_INST="" _WORKER_SSH="" _WORKER_HOST_KEY=""
_WORKER_EXPECTED=""
_WORKER_DEV=false

# _cloudify_worker_phase_of <action> - install->install, configure->
# reconfigure, uninstall->teardown, verify->verify (the result-line mapping).
_cloudify_worker_phase_of() {
    case "$1" in
        install) printf 'install' ;;
        configure) printf 'reconfigure' ;;
        uninstall) printf 'teardown' ;;
        verify) printf 'verify' ;;
        *) return 1 ;;
    esac
}

# _cloudify_worker_step_of <class> - the step id owning the line's work:
# framework lines carry the reserved ids (parent token), everything else the
# caller's step id.
_cloudify_worker_step_of() {
    local class="$1" parent="${_WORKER_LINE[parent]:-}"
    case "$class" in
        framework)
            case "$parent" in
                @defaults) printf 'defaults' ;;
                @init) printf 'init' ;;
                *) return 1 ;;
            esac
            ;;
        *) printf '%s' "$_WORKER_STEP" ;;
    esac
    return 0
}

# _cloudify_worker_summary <class> - the bounded non-secret event summary.
_cloudify_worker_summary() {
    local class="$1" verdict="${_WORKER_LINE[outcome]:-failed}"
    local s
    s="$(_cloudify_worker_phase_of "${_WORKER_LINE[action]:-install}") ${_WORKER_LINE[package]:-}@${_WORKER_LINE[instance]:-} $verdict"
    [[ "$class" == "unrequested" ]] && s="$s (unrequested, observed)"
    [[ "$class" == "framework" ]] && s="$s (framework ${_WORKER_LINE[parent]:-})"
    [[ "$class" == "native" ]] && s="native subject ${_WORKER_LINE[package]:-}: report-only"
    printf '%s' "$s"
}

# _cloudify_worker_commit_line - one classified line's event + inventory
# transition. rc 1 on any failure (fail closed, nothing partial).
#
# Off-graph rule (design: a runtime dependency absent from the precomputed
# graph still reports, and its inventory fails closed): a dependency whose
# instance key the context never precomputed records empty values - none are
# invented after execution - and degrades the run. Every other class without
# a context instance key takes the instance from the line's own report (the
# child resolved it; the worker never guesses) with the global projection.
_cloudify_worker_commit_line() {
    local pkg="${_WORKER_LINE[package]:-}" inst_key values event_values
    [[ -n "$pkg" ]] || { printf 'worker: a result line without a package\n' >&2; return 1; }
    values="$_WORKER_PROJECTION"
    event_values="$_WORKER_EVENT_PROJECTION"
    if [[ -n "${_CLOUDIFY_CONTEXT[package.$pkg.instance]+x}" ]]; then
        inst_key="${_CLOUDIFY_CONTEXT[package.$pkg.instance]}"
    else
        inst_key="${_WORKER_LINE[instance]:-}"
        _cloudify_identity_valid_instance "$inst_key" \
            || { printf 'worker: no instance key for package %s; refusing to invent one\n' "$pkg" >&2; return 1; }
        if [[ "$_WORKER_LINE_CLASS" == "dependency" ]] \
            && [[ -n "${_CLOUDIFY_CONTEXT[package.${_WORKER_LINE[parent]:-}.instance]+x}" ]]; then
            # True off-graph: the parent IS covered by this dispatch's context,
            # the child never was - fail closed (empty values, degraded run).
            values="{}"
            event_values="{}"
            _WORKER_DEGRADED_RUN=true
        fi
        # A dependency under an UNCOVERED parent (framework-descended: the host
        # defaults' own pulls) is outside the requested graph by construction -
        # recorded as observed with the line's own instance key, like natives
        # and unrequested packages. No degraded flag.
    fi

    local record ev_body next step_id phase
    record=$(cloudify_state_record_dir "$_WORKER_NODE" "$_WORKER_INST" \
        "$_WORKER_APP" "$_WORKER_FLAVOR" "$_WORKER_NAME" "$pkg" "$inst_key")/state.json \
        || return 1
    step_id=$(_cloudify_worker_step_of "$_WORKER_LINE_CLASS") || return 1
    phase=$(_cloudify_worker_phase_of "${_WORKER_LINE[action]:-install}") || return 1

    local now outcome="${_WORKER_LINE[outcome]:-failed}"
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Current applied/health pass through unchanged unless this line replaces
    # them (a failed attempt never overwrites applied; verification not-run
    # leaves health as it was).
    local cur_applied cur_health
    if [[ -f "$record" ]]; then
        cur_applied=$(jq -c '.applied' "$record" 2>/dev/null) || cur_applied=null
        cur_health=$(jq -c '.health' "$record" 2>/dev/null) || cur_health=null
    else
        cur_applied=null
        cur_health=null
    fi

    local applied
    if [[ "$outcome" == succeeded ]]; then
        applied=$(jq -cn --arg ver "${_WORKER_LINE[version]:-unknown}" --arg now "$now" \
            --argjson values "$values" \
            '{version: (if $ver == "none" then null else $ver end), at: $now, values: $values, event_id: null}')
    else
        applied="$cur_applied"
    fi

    local health
    case "${_WORKER_LINE[verification]:-not-run}" in
        ok) health=$(jq -cn --arg now "$now" '{status: "ok", checked_at: $now, event_id: null}') ;;
        failed) health=$(jq -cn --arg now "$now" '{status: "degraded", checked_at: $now, event_id: null}') ;;
        *) health="$cur_health" ;;
    esac
    [[ "$health" != "null" ]] || health=$(jq -cn '{status: "unknown", checked_at: null, event_id: null}')

    next=$(jq -cn \
        --arg host "${_WORKER_NODE}${_WORKER_INST:+:$_WORKER_INST}" \
        --arg host_key "$_WORKER_HOST_KEY" \
        --arg pkg "$pkg" --arg inst "$inst_key" \
        --arg app "$_WORKER_APP" --arg flavor "$_WORKER_FLAVOR" --arg name "$_WORKER_NAME" \
        --arg step "$step_id" \
        --argjson applied "$applied" --argjson health "$health" \
        --arg phase "$phase" --arg outcome "$outcome" --arg now "$now" \
        --argjson requested "$values" \
        '{schema_version: 1, host: $host, host_key: $host_key,
          package: $pkg, package_instance: $inst,
          application: $app, flavor: $flavor, deployment: $name, step_id: $step,
          revision: 1, applied: $applied,
          last_attempt: {phase: $phase, outcome: $outcome, at: $now,
                         event_id: null, requested: $requested},
          health: $health}') || return 1

    ev_body=$(jq -cn \
        --arg tool "cloudify" --arg tool_version "$(cloudify_state_writer_identity | jq -r .tool_version)" --argjson writer "$(cloudify_state_writer_identity | jq -c 'del(.tool_version)')" \
        --arg step "$step_id" \
        --arg app "$_WORKER_APP" --arg flavor "$_WORKER_FLAVOR" --arg name "$_WORKER_NAME" \
        --arg commit "$_WORKER_EXPECTED" --argjson dev "$_WORKER_DEV" \
        --arg host "${_WORKER_NODE}${_WORKER_INST:+:$_WORKER_INST}" \
        --arg host_key "$_WORKER_HOST_KEY" \
        --arg pkg "$pkg" --arg inst "$inst_key" \
        --arg phase "$phase" \
        --arg action "${_WORKER_LINE[action]:-install}" \
        --argjson values "$event_values" \
        --argjson exit "${_WORKER_LINE[exit]:-0}" \
        --arg summary "$(_cloudify_worker_summary "$_WORKER_LINE_CLASS")" \
        --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '{schema_version: 1, tool: $tool, tool_version: $tool_version, writer: $writer,
          at: $now,
          run_id: null, step_id: $step,
          application: $app, flavor: $flavor, deployment: $name,
          application_commit: (if $commit == "" then null else $commit end),
          subject: {kind: "package", host: $host, host_key: $host_key,
                    package: $pkg, package_instance: $inst},
          phase: $phase, command_kind: $action, values: $values,
          outcome: {exit_status: $exit, summary: $summary}}
        | . + (if $dev then {development_override: true} else {} end)') || return 1

    local id ev_file next_file
    mkdir -p "$(dirname "$record")"
    ev_file=$(mktemp "$(dirname "$record")/.event-body-XXXXXX") || return 1
    next_file=$(mktemp "$(dirname "$record")/.next-XXXXXX") || { rm -f "$ev_file"; return 1; }
    chmod 600 "$ev_file" "$next_file" 2>/dev/null || true
    printf '%s\n' "$ev_body" > "$ev_file"
    printf '%s\n' "$next" > "$next_file"
    id=$(cloudify_state_inventory_apply "$record" "$ev_file" "$next_file") || {
        rm -f "$ev_file" "$next_file"
        return 1
    }
    rm -f "$ev_file" "$next_file"
    _WORKER_LAST_EVENT="$id"
    return 0
}

# _cloudify_worker_degraded_event <cause> - the worker-level failure event:
# the executed commit is recorded when provable, nothing else is written. An
# undeterminable or divergent checkout records a null commit under the
# development override. Every cause names itself in the summary: a failure
# the line events cannot prove still lands in the stream, so the manifest's
# status stays derivable from events alone.
_cloudify_worker_degraded_event() {
    local cause="$1" summary commit="" override=false
    case "$cause" in
        degraded-mismatch)
            summary="executed-code mismatch: the manifest pins a commit the host did not run"
            commit=$(sed -n 's/^checkout v1: commit=\([0-9a-f]\{40\}\).*/\1/p' "$_WORKER_COLLECTION" | head -n 1) ;;
        degraded-unknown) summary="executed-code unknown: the host could not determine its own checkout"; override=true ;;
        degraded-missing) summary="executed-code missing: no checkout line reached the worker"; override=true ;;
        degraded-divergent) summary="executed-code divergent: the children disagreed on the checkout"; override=true ;;
        validate) summary="collection validation failed: the result stream broke the line contract"; override=true ;;
        reconcile) summary="reconciliation failed: the dispatch graph did not resolve against the collection"; override=true ;;
        context) summary="the dispatch context could not be parsed"; override=true ;;
        classify) summary="the result lines could not be classified"; override=true ;;
        fields) summary="a result line could not be parsed into fields"; override=true ;;
        commit) summary="an inventory commit failed mid-write"; override=true ;;
        degraded-run) summary="degraded run: a dependency outside the dispatch graph recorded empty values"; override=true ;;
        *) return 1 ;;
    esac
    # Early failures parse no context: the event still carries a values
    # object (empty), never a malformed one.
    local values="${_WORKER_EVENT_PROJECTION:-}"
    [[ -n "$values" ]] || values='{}'
    local body id
    body=$(jq -cn \
        --arg tool_version "$(cloudify_state_writer_identity | jq -r .tool_version)" \
        --argjson writer "$(cloudify_state_writer_identity | jq -c 'del(.tool_version)')" \
        --arg step "$_WORKER_STEP" \
        --arg app "$_WORKER_APP" --arg flavor "$_WORKER_FLAVOR" --arg name "$_WORKER_NAME" \
        --arg commit "$commit" --argjson override "$override" \
        --arg phase "$(_cloudify_worker_phase_of "$_WORKER_ACTION")" \
        --arg command "$_WORKER_ACTION" \
        --argjson values "$values" \
        --arg summary "$summary" \
        '{schema_version: 1, tool: "cloudify", tool_version: $tool_version, writer: $writer,
          run_id: null, step_id: $step,
          application: $app, flavor: $flavor, deployment: $name,
          application_commit: (if $commit == "" then null else $commit end),
          subject: {kind: "deployment", host: null, host_key: null,
                    package: null, package_instance: null},
          phase: $phase, command_kind: $command, values: $values,
          outcome: {exit_status: null, summary: $summary},
          state: {previous_revision: null, resulting_revision: null}}
        | . + (if $override then {development_override: true} else {} end)') || return 1
    local body_file
    mkdir -p "$(cloudify_state_events_root)"
    body_file=$(mktemp "$(cloudify_state_events_root)/.degraded-XXXXXX") || return 1
    printf '%s\n' "$body" > "$body_file"
    chmod 600 "$body_file" 2>/dev/null || true
    id=$(cloudify_state_event_create "$body_file") || {
        rm -f "$body_file"
        return 1
    }
    rm -f "$body_file"
    _WORKER_LAST_EVENT="$id"
    return 0
}

# _cloudify_worker_value_names - the resolved names of the parsed context.
_cloudify_worker_value_names() {
    local key p
    for key in "${!_CLOUDIFY_CONTEXT[@]}"; do
        case "$key" in
            value.*.source) p="${key#value.}"; printf '%s\n' "${p%.source}" ;;
        esac
    done | sort
}

# cloudify_worker_process <action> <step-id> <app> <flavor> <name>
#                         <node> <instance> <ssh-host>
#                         <collection-file> <context-file> <bindings-file>
#                         [requested-words...]
# The dispatch worker; see the module header. rc 0 success, rc 1 any failure
# (the manifest still projects, degraded).
# _cloudify_dispatch_worker <action> <node>\t<inst>\t<ssh> <ctx-file> <collection> [words...]
# The router's per-dispatch hook (the last mile): resolve the deployment
# identity from the active application reference, else synthesize the
# reserved `_direct` deployment for a bare dispatch; render the bindings from
# the manifest; run the worker. Called from the final wait loop AFTER the
# dispatch child finishes and BEFORE its context is removed (the worker reads
# the context - it never re-resolves a value). The worker's own exit contract
# stands: records survive, rc says whether the dispatch met its purpose.
function _cloudify_dispatch_worker() {
    # A payload host (the remote child cloudify) has no ivps inventory and no
    # state root of its own: its dispatch is recorded by the CONTROLLER's
    # worker through the captured stream, never locally. Skip, do not fail.
    if ! command -v ivps >/dev/null 2>&1; then
        log_warn "worker: no ivps inventory in this environment (payload host?) - no records"
        return 0
    fi
    local action="${1:?_cloudify_dispatch_worker: action}" triple="${2:?_cloudify_dispatch_worker: target}" \
        ctx="${3:?_cloudify_dispatch_worker: context}" collection="${4:?_cloudify_dispatch_worker: collection}"
    shift 4 || true
    local -a words=("$@")
    local app flavor name step node inst ssh bindings="" _rest
    # Hand-parsed: a tab is IFS-whitespace, `read` collapses the empty
    # instance field (same trap the router's target loop documents).
    node="${triple%%$'\t'*}"
    _rest="${triple#*$'\t'}"
    inst="${_rest%%$'\t'*}"
    ssh="${_rest#*$'\t'}"
    step="${STEP_ID:-direct}"

    # A plain external host (GLOSSARY external host): no ivps inventory home
    # exists for it yet (later phase - keyed by SSH host-key fingerprint). The
    # dispatch ran; the worker names what it cannot do instead of dying on an
    # empty inventory root.
    if [[ -z "$node" ]]; then
        log_warn "worker: plain external host '${ssh:-?}' has no state home yet - the dispatch is recorded nowhere"
        return 0
    fi

    if [[ -n "${CLOUDIFY_APPLICATION:-}" && -n "${CLOUDIFY_FLAVOR:-}" && -n "${CLOUDIFY_DEPLOYMENT_NAME:-}" ]]; then
        app="$CLOUDIFY_APPLICATION" flavor="$CLOUDIFY_FLAVOR" name="$CLOUDIFY_DEPLOYMENT_NAME"
    else
        app="$_DIRECT_APP" flavor="$_DIRECT_FLAVOR"
        name=$(cloudify_state_direct_synthesize "${words[0]:-direct}" "$node" "$inst" "$ssh")
    fi

    bindings=$(mktemp "${CLOUDIFY_TMP:-/tmp}/worker-bindings-XXXXXX") || die "worker hook: cannot create a bindings file."
    cloudify_state_bindings_render "$app" "$flavor" "$name" "$bindings"

    cloudify_worker_process "$action" "$step" "$app" "$flavor" "$name" \
        "$node" "$inst" "$ssh" "$collection" "$ctx" "$bindings" ${words[@]+"${words[@]}"}
    local rc=$?
    rm -f "$bindings"
    return "$rc"
}

function cloudify_worker_process() {
    local action="${1:?}" step="${2:?}" app="${3:?}" flavor="${4:?}" name="${5:?}"
    local node="${6:-}" inst="${7:-}" ssh_host="${8:-}"
    local collection="${9:?}" ctx_file="${10:?}" bindings="${11:?}"
    shift 11 || true
    local -a words=("$@")

    local failed=""
    _WORKER_ACTION="$action" _WORKER_STEP="$step"
    _WORKER_DEGRADED_RUN=false
    _WORKER_APP="$app" _WORKER_FLAVOR="$flavor" _WORKER_NAME="$name"
    _WORKER_NODE="$node" _WORKER_INST="$inst" _WORKER_SSH="$ssh_host"
    _WORKER_HOST_KEY=$(cloudify_state_host_key_of "$node" "$inst")
    _WORKER_COLLECTION="$collection"
    _WORKER_LAST_EVENT=""

    # 1. The host lock, before anything else. A timeout dies named with the
    #    holder metadata - a fail-before-mutation boundary, so nothing projects.
    cloudify_state_host_lock "$node" "$inst"

    # The manifest is the authority for the executed-code check.
    local expected dev
    expected=$(cloudify_manifest_field "$app" "$flavor" "$name" application_commit 2>/dev/null) || expected=""
    [[ "$expected" == "null" ]] && expected=""
    dev=$(cloudify_manifest_field "$app" "$flavor" "$name" development_override 2>/dev/null) || dev=false
    _WORKER_DEV=false
    [[ "$dev" == "true" ]] && _WORKER_DEV=true
    _WORKER_EXPECTED="$expected"

    # 2. Collection validation, then reconciliation - before any write.
    cloudify_results_validate "$collection" || failed="validate"
    if [[ -z "$failed" ]]; then
        cloudify_results_reconcile "$collection" ${words[@]+"${words[@]}"} || failed="reconcile"
    fi

    # The one parsed context and its two event/inventory projections,
    # computed once, before anything consumes them (the executed-code event
    # included).
    if [[ -z "$failed" ]]; then
        cloudify_context_load "$ctx_file" || failed="context"
    fi
    local -a vnames=()
    if [[ -z "$failed" ]]; then
        mapfile -t vnames < <(_cloudify_worker_value_names)
        _WORKER_PROJECTION=$(cloudify_context_values_json "${vnames[@]}")
        _WORKER_EVENT_PROJECTION=$(cloudify_context_event_values_json "${vnames[@]}")
    fi

    # 3. The executed-code verdict.
    local verdict=""
    if [[ -z "$failed" ]]; then
        verdict=$(cloudify_results_check_executed "$collection" "$expected" "$_WORKER_DEV")
        case "$verdict" in
            ok | ok-dev) ;;
            *) failed="executed" ;;
        esac
    fi

    # 4. Ordered commits.
    if [[ -z "$failed" ]]; then
        local -a classes=() bodies=()
        mapfile -t classes < <(cloudify_results_classify "$collection" ${words[@]+"${words[@]}"})
        local line body
        while IFS= read -r line || [[ -n $line ]]; do
            body=$(_cloudify_results_body "$line")
            case "$body" in
                "result v1: "*) bodies+=("$body") ;;
            esac
        done < "$collection"
        if (( ${#classes[@]} != ${#bodies[@]} )); then
            failed="classify"
        else
            local i cls
            for i in "${!classes[@]}"; do
                cls="${classes[i]%%$'\t'*}"   # classify prints class<TAB>package
                _cloudify_results_fields "${bodies[i]}" _WORKER_LINE || { failed="fields"; break; }
                _WORKER_LINE_CLASS="$cls"
                case "$cls" in
                    native)
                        log_warn "worker: native subject ${_WORKER_LINE[package]:-}: report-only, no inventory"
                        ;;
                    requested | dependency | framework | unrequested)
                        [[ "$cls" == "unrequested" ]] &&
                            log_warn "worker: unrequested top-level package ${_WORKER_LINE[package]:-} - recorded as observed"
                        _cloudify_worker_commit_line || { failed="commit"; break; }
                        ;;
                esac
                [[ -n "${_WORKER_LINE[outcome]:-}" && "${_WORKER_LINE[outcome]}" == "failed" ]] && {
                    # The failure split (GLOSSARY manifest status): a failed
                    # line with exit 0 is a verify-stage observation (the
                    # validator forces outcome=failed for it) - information,
                    # not a downgrade; health records it and the event's own
                    # exit 0 keeps the completed work's word. Anything else
                    # is an attempt failure - the non-zero exit on the line
                    # event is the proof, no extra event needed.
                    [[ "${_WORKER_LINE[exit]:-1}" == "0" ]] || failed="attempt"
                }
            done
        fi
    fi

    # The worker-level degraded event: after the verdict, before the unlock.
    # Every failure the line events cannot prove (validation, reconciliation,
    # context, classification, an executed-code verdict, a degraded run)
    # writes its own event - the manifest's word must stay derivable from
    # the event stream alone, or the manifest-as-cache doctrine breaks. A
    # failed attempt needs none: its line event carries the non-zero exit.
    if [[ ( -n "$failed" && "$failed" != "attempt" ) || "$_WORKER_DEGRADED_RUN" == "true" ]]; then
        local _dcause="$failed"
        [[ -n "$_dcause" ]] || _dcause="degraded-run"
        [[ "$_dcause" == "executed" ]] && _dcause="$verdict"
        _cloudify_worker_degraded_event "$_dcause" || true
    fi

    # 5. Release the host lock BEFORE the manifest lock - never both.
    cloudify_state_host_unlock "$node" "$inst"

    # 6. Manifest projection with the explicit last event id. The word comes
    #    from the SAME derivation a rebuild runs - the worker never decides it
    #    a second way (two hand-written copies of one rule drift apart; a
    #    failed verify dispatch degraded in one and was skipped in the other).
    #    A null (nothing new proved itself) keeps the recorded word.
    local status
    status=$(cloudify_state_status_from_events "$app" "$flavor" "$name")
    [[ "$status" == "null" ]] && status=""
    if [[ -z "$status" ]]; then
        status=$(cloudify_manifest_field "$app" "$flavor" "$name" status 2>/dev/null) || status=""
        [[ "$status" == "null" ]] && status=""
    fi
    if ! cloudify_manifest_exists "$app" "$flavor" "$name"; then
        cloudify_state_deployment_create "$app" "$flavor" "$name" "$bindings"
    fi
    local mcommit mdev
    mcommit=$(cloudify_manifest_field "$app" "$flavor" "$name" application_commit 2>/dev/null) || mcommit=""
    [[ "$mcommit" == "null" ]] && mcommit=""
    mdev=$(cloudify_manifest_field "$app" "$flavor" "$name" development_override 2>/dev/null) || mdev=false
    cloudify_manifest_write "$app" "$flavor" "$name" "$status" "$mcommit" "$mdev" "$bindings" "$_WORKER_LAST_EVENT" \
        || return 1

    # A failed attempt, an off-graph dependency, or any worker failure is the
    # dispatch failing its purpose - the commits and the degraded projection
    # stand, the exit says so. Named, never quiet: a silent red is undebuggable.
    if [[ -n "$failed" || "$_WORKER_DEGRADED_RUN" == "true" ]]; then
        log_warn "worker: dispatch failed its purpose (cause: ${failed:-degraded-run}); records stand, status degraded"
        return 1
    fi
    return 0
}
