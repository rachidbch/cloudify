#!/usr/bin/env bats
# Integration test: install hub package (GitHub release path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package hub succeeds" {
    run cloudify_install_package hub
    [ "$status" -eq 0 ]
}

@test "hub binary exists after install" {
    [ -x "/usr/local/bin/hub" ]
}

@test "hub binary runs" {
    command -v hub
    run hub --version
    [ "$status" -eq 0 ]
}
