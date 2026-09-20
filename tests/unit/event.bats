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

_apply_event_body() {
    jq -n '{schema_version:1, at:"2026-09-18T10:00:00Z", tool:"cloudify", tool_version:"t",
        writer:{host:"c", boot_id:"3f2a1b0c-4d5e-6f70-8192-a3b4c5d6e7f8", pid:1, process_start_ticks:1},
        run_id:null, step_id:"install-guac", application:"k3s", flavor:"default", deployment:"main",
        application_commit:"0123456789abcdef0123456789abcdef01234567",
        subject:{kind:"package", host:"cloudai:cloudify", host_key:"ivps:cloudai:cloudify",
                 package:"guacamole", package_instance:"default"},
        phase:"install", command_kind:"install", values:{},
        outcome:{exit_status:0, summary:"apply"}}'
}

_capture() {
    jq -n '{schema_version:1, host:"cloudai:cloudify", host_key:"ivps:cloudai:cloudify",
        package:"guacamole", package_instance:"default",
        application:"k3s", flavor:"default", deployment:"main", step_id:"install-guac",
        applied:{version:"1.5.5", at:"2026-09-18T10:00:01Z", values:{}},
        last_attempt:{phase:"install", outcome:"succeeded", at:"2026-09-18T10:00:01Z", requested:{}},
        health:{status:"unknown", checked_at:null}}'
}

@test "inventory apply: event first, then revision 1 on a fresh record" {
    local record="$CLOUDIFY_TMP/state.json" body="$CLOUDIFY_TMP/ev.json" next="$CLOUDIFY_TMP/next.json"
    _apply_event_body > "$body"
    _capture > "$next"
    local id
    id=$(cloudify_state_inventory_apply "$record" "$body" "$next")
    [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]

    local event_file
    event_file="$HOME/.local/state/cloudify/events/${id:0:4}-${id:4:2}/$id.json"
    [ -f "$event_file" ]
    [ "$(jq -r .state.previous_revision "$event_file")" = "0" ]
    [ "$(jq -r .state.resulting_revision "$event_file")" = "1" ]

    [ "$(jq -r .revision "$record")" = "1" ]
    [ "$(jq -r .applied.event_id "$record")" = "$id" ]
    [ "$(jq -r .last_attempt.event_id "$record")" = "$id" ]
    run cloudify_state_validate_file "$CLOUDIFY_SCHEMA_DIR/package-state.schema.json" "$record"
    [ "$status" -eq 0 ]
}

@test "inventory apply: second transition stamps only the changed object" {
    local record="$CLOUDIFY_TMP/state.json" next2="$CLOUDIFY_TMP/next2.json"
    local body="$CLOUDIFY_TMP/ev.json" id1
    _apply_event_body > "$body"
    _capture > "$CLOUDIFY_TMP/next.json"
    id1=$(cloudify_state_inventory_apply "$record" "$body" "$CLOUDIFY_TMP/next.json")

    jq '.last_attempt = {phase:"reconfigure", outcome:"failed", at:"2026-09-18T11:00:00Z", requested:{}}' \
        "$record" > "$next2"
    local id2
    id2=$(cloudify_state_inventory_apply "$record" "$body" "$next2")
    [ "$id2" != "$id1" ]

    [ "$(jq -r .revision "$record")" = "2" ]
    [ "$(jq -r .applied.event_id "$record")" = "$id1" ]
    [ "$(jq -r .last_attempt.event_id "$record")" = "$id2" ]
}

@test "inventory apply: missing referenced event blocks mutation; invalid next capture writes nothing" {
    local record="$CLOUDIFY_TMP/state.json" body="$CLOUDIFY_TMP/ev.json" next="$CLOUDIFY_TMP/next.json"
    _apply_event_body > "$body"
    _capture > "$next"
    local id1
    id1=$(cloudify_state_inventory_apply "$record" "$body" "$next")
    local before
    before=$(jq -S . "$record")

    subrubric "a record pointing at a missing event refuses to mutate"
    find "$HOME/.local/state/cloudify/events" -name "$id1.json" -delete
    jq '.last_attempt = {phase:"verify", outcome:"failed", at:"2026-09-18T12:00:00Z", requested:{}}' \
        "$record" > "$next"
    run cloudify_state_inventory_apply "$record" "$body" "$next"
    [ "$status" -ne 0 ]
    [ "$(jq -S . "$record")" = "$before" ]

    subrubric "an invalid next capture creates no event and leaves prior bytes"
    _capture > "$next"
    jq 'del(.applied)' "$next" > "$CLOUDIFY_TMP/bad-next.json"
    local events_before
    events_before=$(find "$HOME/.local/state/cloudify/events" -name '*.json' | wc -l)
    run cloudify_state_inventory_apply "$record" "$body" "$CLOUDIFY_TMP/bad-next.json"
    [ "$status" -ne 0 ]
    [ "$(find "$HOME/.local/state/cloudify/events" -name '*.json' | wc -l)" -eq "$events_before" ]
    [ "$(jq -S . "$record")" = "$before" ]
}
