#!/usr/bin/env bats
# Integration test: install gh package (GitHub release path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package gh succeeds" {
    run cloudify_install_package gh
    [ "$status" -eq 0 ]
}

@test "gh binary exists after install" {
    [ -x "/usr/local/bin/gh" ]
}

@test "gh binary runs" {
    command -v gh
    run gh --version
    [ "$status" -eq 0 ]
}
