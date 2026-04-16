#!/usr/bin/env bats
# Integration test: install fd package (GitHub release path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install fd succeeds" {
    run cloudify --on "$TEST_HOST" install fd
    [ "$status" -eq 0 ]
}

@test "fd binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v fd'
    [ "$status" -eq 0 ]
}

@test "fd binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'fd --version'
    [ "$status" -eq 0 ]
}
