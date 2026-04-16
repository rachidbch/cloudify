#!/usr/bin/env bats
# Integration test: install hub package (GitHub release path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install hub succeeds" {
    run cloudify --on "$TEST_HOST" install hub
    [ "$status" -eq 0 ]
}

@test "hub binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v hub'
    [ "$status" -eq 0 ]
}

@test "hub binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'hub --version'
    [ "$status" -eq 0 ]
}
