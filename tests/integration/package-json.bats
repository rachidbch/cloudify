#!/usr/bin/env bats
# Integration test: install json package (apt path — installs jq)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package json succeeds" {
    run cloudify_install_package json
    [ "$status" -eq 0 ]
}

@test "jq binary exists after install" {
    command -v jq
}

@test "jq binary runs" {
    run jq --version
    [ "$status" -eq 0 ]
}
