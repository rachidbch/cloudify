#!/usr/bin/env bats
# Seed wiring freeze (state-model-v2 4.4, ADR-030): a configure dispatch under
# an active application reference resolves as a reconfigure of that deployment
# - it seeds the applied SET values through the dispatch context machinery.
# A bare configure (no application reference) stays an unseeded raw dispatch.
# Local verify under an application reference seeds every applied value before
# the recipe runs.

source tests/helpers/common.bash

NODE_DIR=""

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
    unset XDG_STATE_HOME
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    export CLOUDIFY_DISABLE_COLORS=true

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/vars.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/packages.sh
    source lib/deployments.sh
    source lib/state.sh
    source lib/context.sh
    source lib/remote.sh
    _fake_ivps

    mkdir -p "$CLOUDIFY_DIR/pkg/nginx"
    printf 'PORT=\nASET=\n' > "$CLOUDIFY_DIR/pkg/nginx/.remote-vars"

    export CLOUDIFY_CONTEXT_FILE="$CLOUDIFY_TMP/ctx"
    export CLOUDIFY_CONTEXT_TARGET=$'web1\t\tlocalhost'
}

teardown() {
    teardown_test_env
}

_nv() {
    printf '{"source":"%s","secret":false,"declaration":"none","source_form":"%s","reference":null,"digest":null,"redacted":false}' "$1" "$2"
}

_seed_record() {
    local applied="$1" dir
    dir=$(cloudify_state_record_dir web1 "" web default main nginx default)
    mkdir -p "$dir"
    jq -n --argjson values "$applied" \
        '{schema_version: 1, host: "web1", host_key: "ivps:n1",
          package: "nginx", package_instance: "default",
          application: "web", flavor: "default", deployment: "main",
          step_id: "direct", revision: 1,
          applied: {version: "1.24.0", at: "2026-09-21T00:00:00Z",
                    event_id: "20260101T000000Z-00000002", values: $values},
          last_attempt: {phase: "install", outcome: "succeeded",
                         at: "2026-09-21T00:00:00Z",
                         event_id: "20260101T000000Z-00000000", requested: {}},
          health: {status: "unknown", checked_at: null,
                   event_id: "20260101T000000Z-00000001"}}' > "$dir/state.json"
}

@test "configure dispatch: an active application reference seeds the applied set values" {
    _seed_record "{\"PORT\": $(_nv caller 4000)}"
    export CLOUDIFY_APPLICATION=web CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=main
    unset PORT

    _cloudify_dispatch_vars /dev/null configure deployment reconfigure nginx > /dev/null

    [ -n "${CLOUDIFY_APPLIED_SEED:-}" ]
    [ -f "$CLOUDIFY_APPLIED_SEED" ]
    [ "${PORT:-}" = "4000" ]
    [ "$(cloudify_context_read "$CLOUDIFY_CONTEXT_FILE" value.PORT.raw)" = "t:4000" ]
    [ "$(cloudify_context_read "$CLOUDIFY_CONTEXT_FILE" phase)" = "reconfigure" ]
}

@test "configure dispatch: a bare configure stays an unseeded raw dispatch" {
    _seed_record "{\"PORT\": $(_nv caller 4000)}"
    unset CLOUDIFY_APPLICATION CLOUDIFY_FLAVOR CLOUDIFY_DEPLOYMENT_NAME
    unset PORT
    unset CLOUDIFY_APPLIED_SEED

    _cloudify_dispatch_vars /dev/null configure deployment reconfigure nginx > /dev/null

    [ -z "${CLOUDIFY_APPLIED_SEED:-}" ]
    [ -z "${PORT:-}" ]
}

@test "configure dispatch: a synthesized _direct name never seeds - no records demanded" {
    rubric "ADR-032's invocation-minted name is an observation bucket: a bare configure after a bare install must not die on records minted seconds ago"
    export CLOUDIFY_APPLICATION=_direct CLOUDIFY_FLAVOR=direct CLOUDIFY_DEPLOYMENT_NAME=nginx-20260930T000000Z
    export CLOUDIFY_DEPLOYMENT_SYNTHESIZED=true
    unset PORT
    unset CLOUDIFY_APPLIED_SEED

    _cloudify_dispatch_vars /dev/null configure deployment reconfigure nginx > /dev/null

    [ -z "${CLOUDIFY_APPLIED_SEED:-}" ]
    [ -z "${PORT:-}" ]

    unset CLOUDIFY_DEPLOYMENT_SYNTHESIZED
}

@test "verify seed env: a synthesized name skips the local verify seed too" {
    _seed_record "{}"
    export CLOUDIFY_APPLICATION=web CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=main
    export CLOUDIFY_DEPLOYMENT_SYNTHESIZED=true
    unset CLOUDIFY_APPLIED_SEED

    _cloudify_verify_seed_env nginx

    [ -z "${CLOUDIFY_APPLIED_SEED:-}" ]
    unset CLOUDIFY_DEPLOYMENT_SYNTHESIZED
}

@test "configure dispatch: an application reference with no applied record dies named" {
    export CLOUDIFY_APPLICATION=web CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=main

    run _cloudify_dispatch_vars /dev/null configure deployment reconfigure nginx
    [ "$status" -ne 0 ]
    [[ "$output" == *"no inventory record"* ]]
}

@test "local verify: an active application reference seeds every applied value into the verify environment" {
    _seed_record "{\"ASET\": $(_nv caller 4000)}"
    export CLOUDIFY_APPLICATION=web CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=main
    unset ASET

    _cloudify_verify_seed_env nginx

    [ -n "${CLOUDIFY_APPLIED_SEED:-}" ]
    [ "${ASET:-}" = "4000" ]
    [ "$(cloudify_context_read "$CLOUDIFY_CONTEXT_FILE" phase)" = "verify" ]
}

@test "local verify: no application reference keeps the legacy unseeded path" {
    unset CLOUDIFY_APPLICATION CLOUDIFY_FLAVOR CLOUDIFY_DEPLOYMENT_NAME
    unset CLOUDIFY_APPLIED_SEED

    _cloudify_verify_seed_env nginx

    [ -z "${CLOUDIFY_APPLIED_SEED:-}" ]
}

@test "a failed value-context build aborts the dispatch - no payload ships" {
    # Twin-proof finding 2: the caller must guard _cloudify_dispatch_vars.
    # Tuple active + target set, but NO inventory record: the seed producer
    # dies "no inventory record". The dispatch must abort before any ssh;
    # before the guard it shipped an empty payload and exited green.
    export CLOUDIFY_APPLICATION=web CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=main
    export CLOUDIFY_DEPLOYMENT=web.main
    local stub_dir
    stub_dir=$(mktemp -d)
    printf '#!/bin/bash\necho "SSH-CALLED $*" >> "%s/ssh.log"\nexit 0\n' "$stub_dir" > "$stub_dir/ssh"
    chmod +x "$stub_dir/ssh"
    # The `if !` wrapper suspends errexit for the command - the mode the
    # router's wrapped dispatch contexts run in (the twin-proof swallow). bats'
    # own ERR trap (inherited through set -E) would abort the call instead, so
    # the test clears it first to mirror a trap-clean dispatch context.
    trap - ERR
    local rc=0
    if ! PATH="$stub_dir:$PATH" cloudify_remote_sync web1 configure nginx; then rc=1; fi
    [ "$rc" -eq 1 ]
    [[ ! -f "$stub_dir/ssh.log" ]]
}

@test "remote verify dispatch: the router provides the resolved target to the applied seed" {
    # The seed block reads CLOUDIFY_CONTEXT_TARGET (else the localhost-only
    # _CLOUDIFY_CUR_TARGET); until the router exported the resolved triple,
    # every runbook verify or configure step under an active tuple died
    # "no target resolved for the applied seed" (the two-host e2e finding).
    _seed_record "{\"ASET\": $(_nv caller 4000)}"
    export CLOUDIFY_APPLICATION=web CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=main
    unset CLOUDIFY_CONTEXT_TARGET
    export CLOUDIFY_REMOTE_USER=root CLOUDIFY_REMOTE_PWD=dummy CLOUDIFY_SKIPCREDENTIALS=true
    local stub_dir out
    stub_dir=$(mktemp -d)
    printf '#!/bin/bash\necho "SSH-CALLED $*" >> "%s/ssh.log"\ncat >/dev/null\nexit 0\n' "$stub_dir" "$stub_dir" > "$stub_dir/ssh"
    chmod +x "$stub_dir/ssh"
    out=$(PATH="$stub_dir:$PATH" bash cloudify --on web1 verify nginx 2>&1) || true
    [[ -f "$stub_dir/ssh.log" ]]
    [[ "$out" != *"no target resolved"* ]]
}
