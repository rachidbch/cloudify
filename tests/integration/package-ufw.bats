#!/usr/bin/env bats
# Integration test: install ufw package (apt path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package ufw succeeds" {
    run cloudify_install_package ufw
    [ "$status" -eq 0 ]
}

@test "ufw binary exists after install" {
    command -v ufw
}

@test "ufw binary runs" {
    run ufw version
    [ "$status" -eq 0 ]
}
