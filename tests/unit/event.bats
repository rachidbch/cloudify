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

_event_body() {
    jq -n '{schema_version:1, at:"2026-09-18T10:00:00Z", tool:"cloudify", tool_version:"t",
        writer:{host:"c", boot_id:"3f2a1b0c-4d5e-6f70-8192-a3b4c5d6e7f8", pid:1, process_start_ticks:1},
        run_id:null, step_id:null, application:null, flavor:null, deployment:null, application_commit:null,
        subject:{kind:"deployment", host:null, host_key:null, package:null, package_instance:null},
        phase:"install", command_kind:"install", values:{},
        outcome:{exit_status:null, summary:"probe"}, state:{previous_revision:null, resulting_revision:null}}'
}

@test "event create: renders, validates, hard-links at the canonical path" {
    local body="$CLOUDIFY_TMP/ev.json"
    _event_body > "$body"
    local id
    id=$(cloudify_state_event_create "$body")
    [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]
    local path="$HOME/.local/state/cloudify/events/${id:0:4}-${id:4:2}/$id.json"
    [ -f "$path" ]
    [ "$(stat -c '%a' "$path")" = "600" ]
    run cloudify_state_validate_file "$CLOUDIFY_SCHEMA_DIR/event.schema.json" "$path"
    [ "$status" -eq 0 ]
    [ "$(jq -r .event_id "$path")" = "$id" ]

    subrubric "a second create commits a second immutable event"
    local id2
    id2=$(cloudify_state_event_create "$body")
    [ "$id2" != "$id" ]
    [ -f "$HOME/.local/state/cloudify/events/${id2:0:4}-${id2:4:2}/$id2.json" ]
}

@test "event create: a pinned id that already exists is refused, bytes unchanged" {
    local body="$CLOUDIFY_TMP/ev.json" body2="$CLOUDIFY_TMP/ev2.json"
    _event_body > "$body"
    _event_body | jq '.outcome.summary = "original bytes"' > "$body2"
    cloudify_state_event_create "$body2" "20260101T000000Z-deadbeef" >/dev/null
    local path="$HOME/.local/state/cloudify/events/2026-01/20260101T000000Z-deadbeef.json"

    run cloudify_state_event_create "$body" "20260101T000000Z-deadbeef"
    [ "$status" -ne 0 ]
    [ "$(jq -r .outcome.summary "$path")" = "original bytes" ]
}

@test "event create: no directories on missing schema; a stray temporary is ignored" {
    local body="$CLOUDIFY_TMP/ev.json"
    _event_body > "$body"
    CLOUDIFY_SCHEMA_DIR="$CLOUDIFY_TMP/missing" run cloudify_state_event_create "$body"
    [ "$status" -ne 0 ]
    [ ! -d "$HOME/.local/state/cloudify/events" ]

    local root="$HOME/.local/state/cloudify/events"
    mkdir -p "$root/2026-09"
    echo stray > "$root/2026-09/.event-stray.json"
    local id
    id=$(cloudify_state_event_create "$body")
    [ -f "$root/${id:0:4}-${id:4:2}/$id.json" ]
    [ -f "$root/2026-09/.event-stray.json" ]
}
