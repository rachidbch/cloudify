#!/usr/bin/env bats
# Integration test: install yq package (GitHub release path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package yq succeeds" {
    run cloudify_install_package yq
    [ "$status" -eq 0 ]
}

@test "yq binary exists after install" {
    [ -x "/usr/local/bin/yq" ]
}

@test "yq binary runs" {
    command -v yq
    run yq --version
    [ "$status" -eq 0 ]
}
