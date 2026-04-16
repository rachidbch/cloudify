#!/usr/bin/env bats
# Integration test: install gpg2 package
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package gpg2 succeeds" {
    run cloudify_install_package gpg2
    [ "$status" -eq 0 ]
}

@test "gpg binary exists after install" {
    command -v gpg
}

@test "gpg binary runs" {
    run gpg --version
    [ "$status" -eq 0 ]
}
