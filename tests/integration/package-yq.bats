#!/usr/bin/env bats
# Integration test: install yq package (GitHub release path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install yq succeeds" {
    run cloudify --on "$TEST_HOST" install yq
    [ "$status" -eq 0 ]
}

@test "yq binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v yq'
    [ "$status" -eq 0 ]
}

@test "yq binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'yq --version'
    [ "$status" -eq 0 ]
}
