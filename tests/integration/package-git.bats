#!/usr/bin/env bats
# Integration test: install git package (apt path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package git succeeds" {
    run cloudify_install_package git
    [ "$status" -eq 0 ]
}

@test "git binary exists after install" {
    command -v git
}

@test "git binary runs" {
    # Use 'command' to bypass shadow.sh git() wrapper
    run command git --version
    [ "$status" -eq 0 ]
}
