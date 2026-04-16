#!/usr/bin/env bats
# Integration test: install basics package (apt install path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package basics succeeds" {
    # basics package uses pkg_depends for apt packages
    run cloudify_install_package basics
    [ "$status" -eq 0 ]
}

@test "basics package installs curl" {
    command -v curl
}

@test "basics package installs jq" {
    command -v jq
}

@test "basics package installs tree" {
    command -v tree
}
