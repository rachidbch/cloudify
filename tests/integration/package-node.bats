#!/usr/bin/env bats
# Integration test: install node package via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install node succeeds" {
    run cloudify --on "$TEST_HOST" install node
    [ "$status" -eq 0 ]
}

@test "node binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v node'
    [ "$status" -eq 0 ]
}

@test "npm binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v npm'
    [ "$status" -eq 0 ]
}
