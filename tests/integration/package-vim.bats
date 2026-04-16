#!/usr/bin/env bats
# Integration test: install vim package (apt path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package vim succeeds" {
    run cloudify_install_package vim
    [ "$status" -eq 0 ]
}

@test "vim binary exists after install" {
    command -v vim
}

@test "vim binary runs" {
    run vim --version
    [ "$status" -eq 0 ]
}
