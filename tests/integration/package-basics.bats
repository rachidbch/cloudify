#!/usr/bin/env bats
# Integration test: install basics package (apt install path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install basics succeeds" {
    run cloudify --on "$TEST_HOST" install basics
    [ "$status" -eq 0 ]
}

@test "curl binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v curl'
    [ "$status" -eq 0 ]
}

@test "jq binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v jq'
    [ "$status" -eq 0 ]
}

@test "tree binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v tree'
    [ "$status" -eq 0 ]
}
