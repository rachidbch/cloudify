#!/usr/bin/env bats
# Integration test: install json package (apt path — installs jq) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install json succeeds" {
    run cloudify --on "$TEST_HOST" install json
    [ "$status" -eq 0 ]
}

@test "jq binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v jq'
    [ "$status" -eq 0 ]
}

@test "jq binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'jq --version'
    [ "$status" -eq 0 ]
}
