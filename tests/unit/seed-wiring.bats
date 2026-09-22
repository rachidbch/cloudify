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
