#!/usr/bin/env bats
# Tests for the event substrate helpers (4.1.4): event IDs and writer
# identity. The immutable event writer itself is 4.1.5.

source tests/helpers/common.bash

setup() {
    setup_test_env

    export HOME="$CLOUDIFY_TMP/home"
    mkdir -p "$HOME"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/vars.sh
    source lib/deployments.sh
    source lib/state.sh
}

teardown() {
    teardown_test_env
}

@test "event id: UTC-second shape, random hex suffix, unique across calls" {
    local a b
    a=$(cloudify_state_event_id)
    b=$(cloudify_state_event_id)

    [[ "$a" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]
    [[ "$a" != "$b" ]]
}

@test "writer identity: schema-shaped fields, read once per worker" {
    local w1 w2
    w1=$(cloudify_state_writer_identity)
    w2=$(cloudify_state_writer_identity)

    rubric "read once: identical JSON on every call in this worker"
    [ "$w1" = "$w2" ]

    jq -e '.host | length > 0' <<<"$w1"
    jq -e '.boot_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")' <<<"$w1"
    jq -e '.pid > 0 and .process_start_ticks > 0' <<<"$w1"
    jq -e '.tool_version | length > 0' <<<"$w1"
}
