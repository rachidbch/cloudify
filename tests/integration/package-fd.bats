#!/usr/bin/env bats
# Integration test: install fd package (GitHub release path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package fd succeeds" {
    run cloudify_install_package fd
    [ "$status" -eq 0 ]
}

@test "fd binary exists after install" {
    command -v fd
}

@test "fd binary runs" {
    run fd --version
    [ "$status" -eq 0 ]
}
