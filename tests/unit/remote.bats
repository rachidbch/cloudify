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
