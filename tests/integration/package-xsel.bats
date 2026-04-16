#!/usr/bin/env bats
# Integration test: install xsel package (apt path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install xsel succeeds" {
    run cloudify --on "$TEST_HOST" install xsel
    [ "$status" -eq 0 ]
}

@test "xsel binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v xsel'
    [ "$status" -eq 0 ]
}
