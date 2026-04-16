#!/usr/bin/env bats
# Integration test: install ufw package (apt path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install ufw succeeds" {
    run cloudify --on "$TEST_HOST" install ufw
    [ "$status" -eq 0 ]
}

@test "ufw binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v ufw'
    [ "$status" -eq 0 ]
}

@test "ufw binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'ufw version'
    [ "$status" -eq 0 ]
}
