#!/usr/bin/env bats
# Integration test: install paping package (curl + tar path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package paping succeeds" {
    run cloudify_install_package paping
    [ "$status" -eq 0 ]
}

@test "paping binary exists after install" {
    [ -x "/usr/local/bin/paping" ]
}

@test "paping binary runs" {
    # paping exits 200 on --version (usage), which confirms the binary works
    run paping --version
    [ "$status" -eq 200 ]
}
