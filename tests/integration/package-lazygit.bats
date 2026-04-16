#!/usr/bin/env bats
# Integration test: install lazygit package (GitHub release path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package lazygit succeeds" {
    run cloudify_install_package lazygit
    [ "$status" -eq 0 ]
}

@test "lazygit binary exists after install" {
    [ -x "/usr/local/bin/lazygit" ]
}

@test "lazygit binary runs" {
    command -v lazygit
    run lazygit --version
    [ "$status" -eq 0 ]
}
