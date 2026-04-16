#!/usr/bin/env bats
# Integration test: install mosh package (apt path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package mosh succeeds" {
    run cloudify_install_package mosh
    [ "$status" -eq 0 ]
}

@test "mosh binary exists after install" {
    command -v mosh
}

@test "mosh binary runs" {
    run mosh --version
    [ "$status" -eq 0 ]
}
