#!/usr/bin/env bash
# Dispatch worker freeze (state-model-v2 4.3): one host lock held through
# collection, reconciliation, the executed-code verdict and every ordered
# event+inventory commit; released BEFORE the per-deployment manifest lock
# (never both); manifest projection with an explicit last_event_id.

source tests/helpers/common.bash

NODE_DIR=""
DEP_NAME="main"

_fake_ivps() {
    NODE_DIR="$CLOUDIFY_TMP/nodes/n1"
    local fake_bin="$CLOUDIFY_TMP/bin"
    mkdir -p "$fake_bin" "$NODE_DIR"
    cat > "$fake_bin/ivps" <<STUB
#!/bin/bash
[[ "\$1" = node && "\$2" = path ]] || exit 9
case "\$3" in
    web1) echo "$NODE_DIR" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$fake_bin/ivps"
    export PATH="$fake_bin:$PATH"
}

setup() {
    setup_test_env

    export HOME="$CLOUDIFY_TMP/home"
    mkdir -p "$HOME"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    export CLOUDIFY_NO_VERIFY=true

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/vars.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/packages.sh
    source lib/results.sh
    source lib/deployments.sh
    source lib/state.sh
    source lib/context.sh
    source lib/matching.sh
    source lib/worker.sh
    _fake_ivps

    # Cloudify packages the results can name (is_package reads dirs).
    local p
    for p in nginx openssl curl rsync wezterm; do
        mkdir -p "$CLOUDIFY_DIR/pkg/$p"
        printf '1.0.0\n' > "$CLOUDIFY_DIR/pkg/$p/.version"
    done

    # The deployment the worker projects onto: a proved manifest.
    printf 'primary\tlocalhost\tweb1\t\tlocalhost\n' > "$CLOUDIFY_TMP/bindings"
    cloudify_manifest_write _direct direct "$DEP_NAME" "" \
        0123456789abcdef0123456789abcdef01234567 false "$CLOUDIFY_TMP/bindings"

    # The dispatch context: one resolved name PORT, one covered package.
    {
        printf 'context_version: 1\n'
        printf 'action: install\n'
        printf 'deployment: \n'
        printf 'phase: install\n'
        printf 'target: web1\t\tlocalhost\n'
        printf 'top_kind: package\n'
        printf 'value.PORT.source: environment\n'
        printf 'value.PORT.form: literal\n'
        printf 'value.PORT.secret: false\n'
        printf 'value.PORT.declaration: none\n'
        printf 'value.PORT.reference: \n'
        printf 'value.PORT.digest: \n'
        printf 'value.PORT.raw: t:8080\n'
        printf 'package.nginx.instance: default\n'
        printf 'package.openssl.instance: default\n'
        printf 'package.curl.instance: default\n'
        printf 'package.rsync.instance: default\n'
        printf 'package.wezterm.instance: default\n'
    } > "$CLOUDIFY_TMP/ctx"
}

teardown() {
    teardown_test_env
}

# res <parent> <package> <outcome> <exit> <verification> <version> [instance]
res() {
    printf 'result v1: parent=%s package=%s instance=%s phase=install action=install outcome=%s exit=%s verification=%s version=%s\n' \
        "$1" "$2" "${7:-default}" "$3" "$4" "$5" "$6"
}

checkout() { # checkout <commit>
    printf 'checkout v1: commit=%s dirty=false\n' "$1"
}

collect() {
    printf '%s\n' "$@" > "$CLOUDIFY_TMP/collected"
}

# run_worker [words...] - the standard worker invocation over the fixtures.
run_worker() {
    cloudify_worker_process install direct _direct direct "$DEP_NAME" \
        web1 "" localhost \
        "$CLOUDIFY_TMP/collected" "$CLOUDIFY_TMP/ctx" "$CLOUDIFY_TMP/bindings" "$@"
}

events_root() { printf '%s' "$HOME/.local/state/cloudify/events"; }

record() { # record <pkg> [inst]
    printf '%s' "$(cloudify_state_record_dir web1 "" _direct direct "$DEP_NAME" "$1" "${2:-default}")/state.json"
}

@test "worker: ordered commits - requested, dependency, framework recorded in order; unrequested recorded and surfaced; native report-only" {
    collect "$(checkout 0123456789abcdef0123456789abcdef01234567)" \
        "$(res - nginx succeeded 0 ok 1.24.0)" \
        "$(res nginx openssl succeeded 0 not-run 3.0.0)" \
        "$(res @defaults curl succeeded 0 ok 1.0.0)" \
        "$(res @init rsync succeeded 0 ok 1.0.0)" \
        "$(res - wezterm succeeded 0 ok 2.0.0)" \
        "$(res - native-tool succeeded 0 not-run none)"

    run run_worker nginx
    [ "$status" -eq 0 ]
    [[ "$output" == *"wezterm"* ]]       # the unrequested package is surfaced
    [[ "$output" == *"native-tool"* ]]   # the native subject is reported

    # Five records, one per committed line; per-record revisions are 1 (the
    # ordering guarantee is per record, proven by test 4's repeat run).
    local i rev
    for i in nginx openssl curl rsync wezterm; do
        [ -f "$(record "$i")" ] || { echo "missing record: $i"; false; }
        rev=$(jq -r .revision "$(record "$i")")
        echo "rev[$i]=$rev"
        [ "$rev" = "1" ]
    done

    # Attribution: framework work carries the reserved step ids.
    [ "$(jq -r .step_id "$(record curl)")" = "defaults" ]
    [ "$(jq -r .step_id "$(record rsync)")" = "init" ]
    [ "$(jq -r .step_id "$(record nginx)")" = "direct" ]
    [ "$(jq -r .step_id "$(record wezterm)")" = "direct" ]

    # Applied facts: version on the successful requested line.
    [ "$(jq -r .applied.version "$(record nginx)")" = "1.24.0" ]
    # The native subject wrote no inventory and no event.
    [ ! -e "$(cloudify_state_record_dir web1 "" _direct direct "$DEP_NAME" native-tool default)" ]
    # Every record's requested values carry the full resolved projection,
    # provenance included: PORT came from the caller env, so it is a set value.
    [ "$(jq -r '.last_attempt.requested.PORT.source_form' "$(record nginx)")" = "8080" ]
    [ "$(jq -r '.last_attempt.requested.PORT.source' "$(record nginx)")" = "caller" ]
    [ "$(jq -r '.applied.values.PORT.source' "$(record nginx)")" = "caller" ]

    # Manifest: success ends installed with the last committed event id.
    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" status)" = "installed" ]
    local last_ev
    last_ev=$(jq -r '.applied.event_id' "$(record wezterm)")
    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" last_event_id)" = "$last_ev" ]
}

@test "worker: an install whose verify stage fails stays installed with failing health" {
    rubric "written-but-unverified is information, not a downgrade"
    collect "$(checkout 0123456789abcdef0123456789abcdef01234567)" \
        "$(res - nginx failed 0 failed 1.24.0)"

    run run_worker nginx
    [ "$status" -eq 0 ]

    # The attempt stood, the verify stage observed failure: health records it,
    # the status stays installed.
    [ "$(jq -r .health.status "$(record nginx)")" = "degraded" ]
    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" status)" = "installed" ]
}

@test "worker: a passing verify dispatch ends verified; a failing one degrades on its failed attempt" {
    rubric "verified arrives only through a real verify observation"
    # An installed deployment to observe.
    collect "$(checkout 0123456789abcdef0123456789abcdef01234567)" \
        "$(res - nginx succeeded 0 ok 1.24.0)"
    run run_worker nginx
    [ "$status" -eq 0 ]
    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" status)" = "installed" ]

    # The verify dispatch passes: verified, as of that moment.
    collect "$(checkout 0123456789abcdef0123456789abcdef01234567)" \
        'result v1: parent=- package=nginx instance=default phase=verify action=verify outcome=succeeded exit=0 verification=ok version=-'
    run_worker_verify() {
        cloudify_worker_process verify direct _direct direct "$DEP_NAME" \
            web1 "" localhost \
            "$CLOUDIFY_TMP/collected" "$CLOUDIFY_TMP/ctx" "$CLOUDIFY_TMP/bindings" "$@"
    }
    run run_worker_verify nginx
    [ "$status" -eq 0 ]
    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" status)" = "verified" ]

    # The next verify fails - the REAL line shape the router emits for a
    # failing verify dispatch (exit 1, verification failed): drift observed,
    # a failed attempt. The dispatch fails its purpose (rc 1), health records
    # it, and the word degrades - the check exists to catch drift.
    collect "$(checkout 0123456789abcdef0123456789abcdef01234567)" \
        'result v1: parent=- package=nginx instance=default phase=verify action=verify outcome=failed exit=1 verification=failed version=-'
    run run_worker_verify nginx
    [ "$status" -eq 1 ]
    [ "$(jq -r .health.status "$(record nginx)")" = "degraded" ]
    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" status)" = "degraded" ]

    subrubric "rebuild agrees with the maintained manifest on the failure path"
    local m
    m=$(cloudify_state_manifest_file _direct direct "$DEP_NAME")
    cp "$m" "$CLOUDIFY_TMP/maintained.json"
    cloudify_state_manifest_rebuild _direct direct "$DEP_NAME"
    cmp -s "$m" "$CLOUDIFY_TMP/maintained.json"
    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" status)" = "degraded" ]
}

@test "worker: a missing requested top-level result fails before any inventory write, manifest degraded" {
    collect "$(checkout 0123456789abcdef0123456789abcdef01234567)" \
        "$(res @defaults curl succeeded 0 ok 1.0.0)"

    run run_worker nginx
    [ "$status" -ne 0 ]
    [[ "$output" == *"nginx"* ]]

    [ ! -e "$(record nginx)" ]
    [ ! -e "$(record curl)" ]
    local events
    events=$(find "$(events_root)" -name '*.json' 2>/dev/null || true)
    # No inventory, but the failure is IN THE STREAM: one worker-level
    # degraded event (reconcile cause, exit_status null) - the manifest's
    # degraded word stays derivable from events alone.
    [ "$(printf '%s\n' "$events" | grep -c .)" -eq 1 ]
    [ "$(jq -r .outcome.exit_status "$events")" = "null" ]
    [ "$(jq -r .command_kind "$events")" = "install" ]
    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" status)" = "degraded" ]
    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" last_event_id)" = "$(basename "$events" .json)" ]
}

@test "worker: executed-code mismatch on a proved dispatch degrades, records the executed commit, writes no inventory" {
    collect "$(checkout fedcba98fedcba98fedcba98fedcba98fedcba98)" \
        "$(res - nginx succeeded 0 ok 1.24.0)"

    run run_worker nginx
    [ "$status" -ne 0 ]

    # No inventory, exactly one event, and it names the executed commit.
    [ ! -e "$(record nginx)" ]
    local events
    events=$(find "$(events_root)" -name '*.json' 2>/dev/null || true)
    [ "$(printf '%s\n' "$events" | grep -c .)" -eq 1 ]
    [ "$(jq -r .application_commit "$events")" = "fedcba98fedcba98fedcba98fedcba98fedcba98" ]

    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" status)" = "degraded" ]
    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" last_event_id)" = "$(basename "$events" .json)" ]

    subrubric "a development-override run never degrades on this check"
    cloudify_manifest_write _direct direct "$DEP_NAME" "" \
        "" true "$CLOUDIFY_TMP/bindings"
    collect "$(checkout fedcba98fedcba98fedcba98fedcba98fedcba98)" \
        "$(res - nginx succeeded 0 ok 1.24.0)"
    run run_worker nginx
    [ "$status" -eq 0 ]
    [ -f "$(record nginx)" ]
}

@test "worker: repeated membership commits in order; a failed attempt preserves applied" {
    collect "$(checkout 0123456789abcdef0123456789abcdef01234567)" \
        "$(res - nginx succeeded 0 ok 1.24.0)" \
        "$(res - nginx failed 1 not-run 1.24.0)"

    run run_worker nginx
    # A failed attempt is the dispatch failing its purpose: rc 1, but both
    # ordered commits stand and the manifest projects degraded.
    [ "$status" -ne 0 ]
    [ "$(jq -r .revision "$(record nginx)")" = "2" ]
    [ "$(jq -r .applied.version "$(record nginx)")" = "1.24.0" ]
    [ "$(jq -r .last_attempt.outcome "$(record nginx)")" = "failed" ]
    # Applied keeps the FIRST event (success); the failed attempt carries its own.
    [ "$(jq -r .applied.event_id "$(record nginx)")" != "$(jq -r .last_attempt.event_id "$(record nginx)")" ]
}

@test "worker: the host lock is held through the commits and released before the manifest lock" {
    collect "$(checkout 0123456789abcdef0123456789abcdef01234567)" \
        "$(res - nginx succeeded 0 ok 1.24.0)"

    subrubric "the worker writes its holder metadata into the host lock file"
    CLOUDIFY_ASSERT_NO_HOST_LOCK=1 run run_worker nginx
    [ "$status" -eq 0 ]
    local lp
    lp=$(cloudify_state_host_lock_path web1)
    [ -f "$lp" ]
    jq -e .host "$lp" >/dev/null

    subrubric "the test-only assertion fires when the manifest lock meets a held host lock"
    cloudify_state_host_lock web1
    run env CLOUDIFY_ASSERT_NO_HOST_LOCK=1 bash -c '
        source lib/utils.sh
        source lib/state.sh
        cloudify_manifest_write _direct direct main installed \
            0123456789abcdef0123456789abcdef01234567 false '"$CLOUDIFY_TMP/bindings"'
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *"host lock"* ]]
    cloudify_state_host_unlock web1
}

@test "worker: a timed-out host lock names the holder and commits nothing" {
    collect "$(checkout 0123456789abcdef0123456789abcdef01234567)" \
        "$(res - nginx succeeded 0 ok 1.24.0)"

    cloudify_state_host_lock web1
    CLOUDIFY_LOCK_TIMEOUT=1 run run_worker nginx
    [ "$status" -ne 0 ]
    [[ "$output" == *"host lock"* ]]
    [[ "$output" == *"host_key"* ]]   # the holder metadata is printed
    [ ! -e "$(record nginx)" ]
    cloudify_state_host_unlock web1
}

@test "worker: an off-graph dependency records a fail-closed inventory and ends degraded on its own event" {
    # A dependency the expanded graph never precomputed: its inventory fails
    # closed (no values invented), and the run is degraded (design).
    collect "$(checkout 0123456789abcdef0123456789abcdef01234567)" \
        "$(res - nginx succeeded 0 ok 1.24.0)" \
        "$(res nginx wezterm succeeded 0 ok 2.0.0)"
    sed -i '/package.wezterm.instance/d' "$CLOUDIFY_TMP/ctx"

    run run_worker nginx
    [ "$status" -ne 0 ]

    # The earlier pair stays valid; the off-graph dependency records its own
    # fail-closed inventory (no values invented after execution).
    [ -f "$(record nginx)" ]
    [ "$(jq -r .revision "$(record nginx)")" = "1" ]
    [ "$(jq -r '.last_attempt.requested | length' "$(record wezterm)")" -eq 0 ]
    [ "$(jq -r '.applied.values | length' "$(record wezterm)")" -eq 0 ]
    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" status)" = "degraded" ]
    # The degraded-run event lands after the line commits: it is the newest,
    # and the word degrades on it (derivable, not asserted from the worker).
    local last_ev
    last_ev=$(cloudify_manifest_field _direct direct "$DEP_NAME" last_event_id)
    [ "$(jq -r ".outcome.exit_status" "$(events_root)/${last_ev:0:4}-${last_ev:4:2}/$last_ev.json")" = "null" ]
    [ "$(jq -r ".outcome.summary" "$(events_root)/${last_ev:0:4}-${last_ev:4:2}/$last_ev.json")" = "degraded run: a dependency outside the dispatch graph recorded empty values" ]
}

@test "worker: a successful run with no inventory commits leaves last_event_id unchanged" {
    collect "$(checkout 0123456789abcdef0123456789abcdef01234567)" \
        "$(res - native-tool succeeded 0 not-run none)"

    run run_worker
    [ "$status" -eq 0 ]
    rubric "no event committed: no state-relevant word, the recorded null stands"
    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" status)" = "null" ]
    [ "$(cloudify_manifest_field _direct direct "$DEP_NAME" last_event_id)" = "null" ]
}
