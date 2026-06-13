#!/usr/bin/env bats
# Integration test: install yazi package (GitHub release .deb) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install yazi succeeds" {
    run cloudify --on "$TEST_HOST" install yazi
    [ "$status" -eq 0 ]
}

@test "yazi binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v yazi'
    [ "$status" -eq 0 ]
}

@test "yazi binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'yazi --version'
    [ "$status" -eq 0 ]
}
