#!/usr/bin/env bats
# Integration test: install entr package (apt path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package entr succeeds" {
    run cloudify_install_package entr
    [ "$status" -eq 0 ]
}

@test "entr binary exists after install" {
    command -v entr
}

@test "entr binary runs" {
    run entr
    [ "$status" -ne 0 ]
}
