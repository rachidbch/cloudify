#!/usr/bin/env bats
# Integration test: install git package (apt path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install git succeeds" {
    run cloudify --on "$TEST_HOST" install git
    [ "$status" -eq 0 ]
}

@test "git binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v git'
    [ "$status" -eq 0 ]
}

@test "git binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'git --version'
    [ "$status" -eq 0 ]
}
