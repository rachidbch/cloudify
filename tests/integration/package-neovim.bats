#!/usr/bin/env bats
# Integration test: install neovim package (apt path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package neovim succeeds" {
    run cloudify_install_package neovim
    [ "$status" -eq 0 ]
}

@test "nvim binary exists after install" {
    command -v nvim
}

@test "nvim binary runs" {
    run nvim --version
    [ "$status" -eq 0 ]
}
