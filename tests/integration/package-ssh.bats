#!/usr/bin/env bats
# Integration test: install ssh package (apt path — installs autossh)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package ssh succeeds" {
    run cloudify_install_package ssh
    [ "$status" -eq 0 ]
}

@test "autossh binary exists after install" {
    command -v autossh
}

@test "autossh binary runs" {
    run autossh -V
    [ "$status" -eq 0 ]
}
