#!/usr/bin/env bats
# The applied-state screen and the unset escape (state-model-v2 4.4, ADR-030):
# show renders hosts (from the manifest bindings) -> packages -> values, the
# USER column marks caller-sourced values only, secrets show dots plus a short
# fingerprint, and the footer names the exact release command. --user-values
# filters to pinned values. unset releases caller pins event-first (source ->
# applied, revision bump under the host lock); a var that is not a user value
# dies named; the released pin stops seeding the next reconfigure.

source tests/helpers/common.bash

NODE_DIR=""
NODE2_DIR=""

_fake_ivps() {
    NODE_DIR="$CLOUDIFY_TMP/nodes/n1"
    NODE2_DIR="$CLOUDIFY_TMP/nodes/n2"
    local fake_bin="$CLOUDIFY_TMP/bin"
    mkdir -p "$fake_bin" "$NODE_DIR" "$NODE2_DIR"
    cat > "$fake_bin/ivps" <<STUB
#!/bin/bash
[[ "\$1" = node && "\$2" = path ]] || exit 9
case "\$3" in
    web1) echo "$NODE_DIR" ;;
    db1) echo "$NODE2_DIR" ;;
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
    source lib/deployments.sh
    source lib/state.sh
    source lib/context.sh
    _fake_ivps

    export CLOUDIFY_APPLICATION=web CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=main
}

teardown() {
    teardown_test_env
}

_nv() { # _nv <source> <form>
    printf '{"source":"%s","secret":false,"declaration":"none","source_form":"%s","reference":null,"digest":null,"redacted":false}' "$1" "$2"
}

_sec() { # _sec <source> <digest>
    printf '{"source":"%s","secret":true,"declaration":"explicit","source_form":null,"reference":null,"digest":"%s","redacted":true}' "$1" "$2"
}

# _ensure_event <id> - the gap check refuses records pointing at missing
# events, so the seeds reference three real (pinned-id) events.
_ensure_event() {
    local id="$1" root f
    root="$HOME/.local/state/cloudify/events/${1:0:4}-${1:4:2}"
    [[ -f "$root/$1.json" ]] && return 0
    local body
    body=$(jq -cn --argjson writer '{"host":"c","boot_id":"3f2a1b0c-4d5e-6f70-8192-a3b4c5d6e7f8","pid":1,"process_start_ticks":1}' \
        '{schema_version: 1, tool: "cloudify", tool_version: "t", writer: $writer,
          run_id: null, step_id: "direct",
          application: "web", flavor: "default", deployment: "main",
          application_commit: "0123456789abcdef0123456789abcdef01234567",
          subject: {kind: "package", host: "web1", host_key: "ivps:n1",
                    package: "nginx", package_instance: "default"},
          phase: "install", command_kind: "install", values: {},
          outcome: {exit_status: 0, summary: "seed"},
          state: {previous_revision: 0, resulting_revision: 1}}')
    local bf
    bf=$(mktemp)
    printf '%s\n' "$body" > "$bf"
    cloudify_state_event_create "$bf" "$id" >/dev/null
    rm -f "$bf"
}

# _seed_record <node> <pkg> <applied-json>
_seed_record() {
    local node="$1" pkg="$2" applied="$3" dir host
    [[ "$node" == web1 ]] && host=web1 || host=db1
    dir=$(cloudify_state_record_dir "$node" "" web default main "$pkg" default)
    mkdir -p "$dir"
    _ensure_event 20260101T000000Z-00000000
    _ensure_event 20260101T000000Z-00000001
    _ensure_event 20260101T000000Z-00000002
    jq -n --arg host "$host" --arg pkg "$pkg" --argjson values "$applied" \
        '{schema_version: 1, host: $host, host_key: "ivps:n1",
          package: $pkg, package_instance: "default",
          application: "web", flavor: "default", deployment: "main",
          step_id: "direct", revision: 1,
          applied: {version: "1.24.0", at: "2026-09-21T16:08:31Z",
                    event_id: "20260101T000000Z-00000002", values: $values},
          last_attempt: {phase: "install", outcome: "succeeded",
                         at: "2026-09-21T16:08:31Z",
                         event_id: "20260101T000000Z-00000000", requested: {}},
          health: {status: "ok", checked_at: null,
                   event_id: "20260101T000000Z-00000001"}}' > "$dir/state.json"
}

_manifest() { # _manifest <binding-line...>
    local bf="$CLOUDIFY_TMP/bf"
    printf '%s\n' "$@" > "$bf"
    cloudify_manifest_write web default main active \
        0123456789abcdef0123456789abcdef01234567 false "$bf"
}

@test "show: hosts -> packages -> values; USER marks caller values only; footer names the release command" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1'
    _seed_record web1 nginx "{\"PORT\": $(_nv deployment 8080), \"TOKEN\": $(_sec caller "sha256:$(printf plain | sha256sum | cut -d' ' -f1)")}"
    _seed_record web1 openssl "{\"MODE\": $(_nv caller fast)}"

    run cloudify_deployment_show main
    [ "$status" -eq 0 ]

    # Host section for the single binding: plain host line.
    printf '%s\n' "$output" | grep -qx "  web1"
    # Package headers with version and health.
    printf '%s\n' "$output" | grep -q "nginx.*1.24.0.*ok"
    printf '%s\n' "$output" | grep -q "openssl.*1.24.0.*ok"
    # Values under their packages; USER only on caller-sourced ones.
    printf '%s\n' "$output" | grep -q "PORT.*8080"
    printf '%s\n' "$output" | grep -q "MODE.*fast.*USER"
    # The secret: dots plus a short fingerprint, never the plaintext.
    [[ "$output" == *"********"* ]]
    [[ "$output" != *"plain"* ]]
    # Header count and the release command with the full signature.
    [[ "$output" == *"nginx TOKEN"* ]]
    [[ "$output" == *"unset web/default/main"* ]]

    # The USER marker appears exactly twice (TOKEN, MODE) and never on PORT.
    local n_user
    n_user=$(grep -c "USER" <<<"$output")
    [ "$n_user" -eq 2 ]
}

@test "list: one rich line per deployment - status, pkgs, hosts, user values" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1'
    _seed_record web1 nginx "{\"PORT\": $(_nv deployment 8080), \"TOKEN\": $(_nv caller abc)}"
    _seed_record web1 openssl "{}"

    run cloudify_deployment_list
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q "web/default/main.*active.*2 pkgs.*1 host.*1 user value"
}

@test "show: multiple bindings render slot -> host; per-host values stay nested" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1' $'db\tlocalhost\tdb1\t\tdb1'
    _seed_record web1 nginx "{\"PORT\": $(_nv deployment 8080)}"
    _seed_record db1 nginx "{\"PORT\": $(_nv deployment 5432)}"

    run cloudify_deployment_show main
    [ "$status" -eq 0 ]
    [[ "$output" == *"primary -> web1"* ]]
    [[ "$output" == *"db -> db1"* ]]
    [[ "$output" == *"8080"* ]]
    [[ "$output" == *"5432"* ]]
}

@test "show --user-values: only pinned values and their packages" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1'
    _seed_record web1 nginx "{\"PORT\": $(_nv deployment 8080), \"TOKEN\": $(_nv caller abc)}"
    _seed_record web1 openssl "{\"MODE\": $(_nv deployment fast)}"

    run cloudify_deployment_show main 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"TOKEN"* ]]
    [[ "$output" == *"USER"* ]]
    [[ "$output" != *"8080"* ]]
    [[ "$output" != *"fast"* ]]
    # The package with no user values drops its value block.
    [[ "$output" == *"nginx"* ]]
    [[ "$output" != *"openssl"* ]]
}

@test "unset: releases the pin event-first; the value stays applied and stops seeding" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1'
    _seed_record web1 nginx "{\"PORT\": $(_nv caller 4000), \"TOKEN\": $(_nv deployment 8080)}"
    local rec
    rec=$(cloudify_state_record_dir web1 "" web default main nginx default)/state.json

    run cloudify_deployment_unset main nginx PORT
    [ "$status" -eq 0 ]

    [ "$(jq -r .revision "$rec")" = "2" ]
    [ "$(jq -r .applied.values.PORT.source "$rec")" = "applied" ]
    [ "$(jq -r .applied.values.PORT.source_form "$rec")" = "4000" ]
    [ "$(jq -r .applied.values.TOKEN.source "$rec")" = "deployment" ]

    # One unset event exists, command_kind unset, phase null.
    local ev
    ev=$(find "$HOME/.local/state/cloudify/events" -name '*.json' -exec jq -r 'select(.command_kind=="unset") | input_filename' {} \;)
    [ -n "$ev" ]
    [ "$(jq -r .phase "$ev")" = "null" ]
    [ "$(jq -r .step_id "$ev")" = "unset" ]

    # The behavioral payoff: the released pin no longer seeds a reconfigure.
    local seed
    seed=$(cloudify_context_applied_seed reconfigure web1 "" web default main)
    if grep -q "^PORT" "$seed"; then false; fi
    if grep -q "^TOKEN" "$seed"; then false; fi   # store-sourced: excluded from the set filter
}

@test "unset: a var that is not a user value dies named, nothing changes" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1'
    _seed_record web1 nginx "{\"PORT\": $(_nv deployment 8080)}"
    local rec
    rec=$(cloudify_state_record_dir web1 "" web default main nginx default)/state.json
    local before
    before=$(jq -S . "$rec")

    run cloudify_deployment_unset main nginx PORT
    [ "$status" -ne 0 ]
    [[ "$output" == *"PORT"* ]]
    [ "$(jq -S . "$rec")" = "$before" ]
}

@test "unset: unknown deployment or package dies named" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1'
    _seed_record web1 nginx "{\"PORT\": $(_nv caller 4000)}"

    # An id resolves only outside an active application reference (the
    # reference wins otherwise) - the operator-shell case.
    unset CLOUDIFY_APPLICATION CLOUDIFY_FLAVOR CLOUDIFY_DEPLOYMENT_NAME
    run cloudify_deployment_unset nosuch nginx PORT
    [ "$status" -ne 0 ]
    export CLOUDIFY_APPLICATION=web CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=main
    run cloudify_deployment_unset main nosuchpkg PORT
    [ "$status" -ne 0 ]
}
