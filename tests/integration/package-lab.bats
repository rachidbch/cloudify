#!/usr/bin/env bats
# Integration test: install lab package (GitHub release path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package lab succeeds" {
    run cloudify_install_package lab
    [ "$status" -eq 0 ]
}

@test "lab binary exists after install" {
    [ -x "/usr/local/bin/lab" ]
}

@test "lab binary runs" {
    command -v lab
    run lab --version
    [ "$status" -eq 0 ]
}
