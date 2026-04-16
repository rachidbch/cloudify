#!/usr/bin/env bats
# Integration test: install tmux package (apt path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package tmux succeeds" {
    run cloudify_install_package tmux
    [ "$status" -eq 0 ]
}

@test "tmux binary exists after install" {
    command -v tmux
}

@test "tmux binary runs" {
    run tmux -V
    [ "$status" -eq 0 ]
}
