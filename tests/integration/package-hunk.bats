#!/usr/bin/env bats
# Integration test: install hunk package (npm global path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install hunk succeeds" {
    run cloudify --on "$TEST_HOST" install hunk
    [ "$status" -eq 0 ]
}

@test "hunk binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v hunk'
    [ "$status" -eq 0 ]
}

@test "hunk binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'hunk --version'
    [ "$status" -eq 0 ]
}
