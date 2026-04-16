#!/usr/bin/env bats
# Integration test: install mosh package (apt path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install mosh succeeds" {
    run cloudify --on "$TEST_HOST" install mosh
    [ "$status" -eq 0 ]
}

@test "mosh binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v mosh'
    [ "$status" -eq 0 ]
}

@test "mosh binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'mosh --version'
    [ "$status" -eq 0 ]
}
