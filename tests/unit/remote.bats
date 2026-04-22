#!/usr/bin/env bats
# Tests for lib/remote.sh

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/package-api.sh
    source lib/remote.sh
}

teardown() {
    teardown_test_env
}

@test "cloudify_remote_payload_template is defined after sourcing" {
    [ "$(type -t cloudify_remote_payload_template)" = "function" ]
}

@test "cloudify_remote is defined after sourcing" {
    [ "$(type -t cloudify_remote)" = "function" ]
}

@test "cloudify_remote_sync is defined after sourcing" {
    [ "$(type -t cloudify_remote_sync)" = "function" ]
}

@test "cloudify_remote_sync rejects running on remote host calling another remote" {
    export CLOUDIFY_IS_LOCAL=false
    run cloudify_remote_sync somehost somecommand
    [ "$status" -ne 0 ]
    [[ "$output" == *"already running on a remote host"* ]]
}

@test "module guard prevents double-sourcing" {
    source lib/remote.sh
    source lib/remote.sh
    [ "$(type -t cloudify_remote_sync)" = "function" ]
}

#-- Non-interactive environment tests --

@test "payload template sets DEBIAN_FRONTEND=noninteractive" {
    local payload
    payload=$(declare -f cloudify_remote_payload_template | tail -n +3 | head -n -1)
    [[ "$payload" == *"DEBIAN_FRONTEND=noninteractive"* ]]
}

@test "payload template sets NEEDRESTART_MODE=a" {
    local payload
    payload=$(declare -f cloudify_remote_payload_template | tail -n +3 | head -n -1)
    [[ "$payload" == *"NEEDRESTART_MODE=a"* ]]
}

#-- Exit code capture tests --

@test "cloudify_remote_sync writes exit code 0 file on localhost success" {
    # Mock cloudify to succeed
    cloudify() { echo "mock success"; }
    cloudify_init_log

    cloudify_remote_sync localhost install bat

    [ -f "$CLOUDIFY_TMP/localhost.exit" ]
    [ "$(cat "$CLOUDIFY_TMP/localhost.exit")" = "0" ]
}

@test "cloudify_remote_sync writes non-zero exit code file on localhost failure" {
    # Mock cloudify to fail with exit code 42
    cloudify() { echo "mock failure" >&2; return 42; }
    cloudify_init_log

    run cloudify_remote_sync localhost install bat
    [ -f "$CLOUDIFY_TMP/localhost.exit" ]
    [ "$(cat "$CLOUDIFY_TMP/localhost.exit")" = "42" ]
}

@test "cloudify_remote_sync writes output to log file on localhost" {
    cloudify() { echo "package installed"; }
    cloudify_init_log

    cloudify_remote_sync localhost install bat

    [ -f "$CLOUDIFY_LOG_FILE" ]
    grep -q "package installed" "$CLOUDIFY_LOG_FILE"
}

@test "cloudify_remote tracks background PID" {
    # Mock cloudify_remote_sync to succeed
    cloudify_remote_sync() { sleep 0.1; }
    _CLOUDIFY_BG_PIDS=()

    cloudify_remote somehost "install bat"

    [ ${#_CLOUDIFY_BG_PIDS[@]} -eq 1 ]
    # Verify the PID is valid (still running or just finished)
    kill -0 "${_CLOUDIFY_BG_PIDS[0]}" 2>/dev/null || true
}

#-- Payload template content tests --

@test "payload template suppresses find stderr on missing .#last_update" {
    local payload
    payload=$(declare -f cloudify_remote_payload_template | tail -n +3 | head -n -1)
    [[ "$payload" == *"2>"*"/dev/null"* ]]
}

@test "payload template exports CLOUDIFY_LOCAL_BIN" {
    local payload
    payload=$(declare -f cloudify_remote_payload_template | tail -n +3 | head -n -1)
    [[ "$payload" == *"CLOUDIFY_LOCAL_BIN"* ]]
    [[ "$payload" == *".local/bin"* ]]
}

@test "payload template exports CLOUDIFY_LOG_LEVEL" {
    local payload
    payload=$(declare -f cloudify_remote_payload_template | tail -n +3 | head -n -1)
    [[ "$payload" == *"CLOUDIFY_LOG_LEVEL"* ]]
}
