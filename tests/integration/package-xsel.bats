#!/usr/bin/env bats
# Integration test: install xsel package (apt path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package xsel succeeds" {
    run cloudify_install_package xsel
    [ "$status" -eq 0 ]
}

@test "xsel binary exists after install" {
    command -v xsel
}
