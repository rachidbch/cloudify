#!/usr/bin/env bats
# Integration test: install rclone package (GitHub release path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install rclone succeeds" {
    run cloudify --on "$TEST_HOST" install rclone
    [ "$status" -eq 0 ]
}

@test "rclone binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v rclone'
    [ "$status" -eq 0 ]
}

@test "rclone binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'rclone --version'
    [ "$status" -eq 0 ]
}
