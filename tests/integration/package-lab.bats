#!/usr/bin/env bats
# Integration test: install lab package via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install lab succeeds" {
    run cloudify --on "$TEST_HOST" install lab
    [ "$status" -eq 0 ]
}

@test "lab binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v lab'
    [ "$status" -eq 0 ]
}

@test "lab binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'lab --version'
    [ "$status" -eq 0 ]
}
