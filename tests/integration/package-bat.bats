#!/usr/bin/env bats
# Integration test: install bat package (GitHub release path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install bat succeeds" {
    run cloudify --on "$TEST_HOST" install bat
    [ "$status" -eq 0 ]
}

@test "bat binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v bat'
    [ "$status" -eq 0 ]
}

@test "bat binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'bat --version'
    [ "$status" -eq 0 ]
}
