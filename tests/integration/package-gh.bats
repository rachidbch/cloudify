#!/usr/bin/env bats
# Integration test: install gh package (GitHub release path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install gh succeeds" {
    run cloudify --on "$TEST_HOST" install gh
    [ "$status" -eq 0 ]
}

@test "gh binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v gh'
    [ "$status" -eq 0 ]
}

@test "gh binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'gh --version'
    [ "$status" -eq 0 ]
}
