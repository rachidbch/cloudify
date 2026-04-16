#!/usr/bin/env bats
# Integration test: install rclone package (GitHub release path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package rclone succeeds" {
    run cloudify_install_package rclone
    [ "$status" -eq 0 ]
}

@test "rclone binary exists after install" {
    [ -x "/usr/local/bin/rclone" ] || [ -x "/usr/bin/rclone" ]
}

@test "rclone binary runs" {
    command -v rclone
    run rclone --version
    [ "$status" -eq 0 ]
}
