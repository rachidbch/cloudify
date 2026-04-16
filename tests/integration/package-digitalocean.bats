#!/usr/bin/env bats
# Integration test: install digitalocean (doctl) package via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install digitalocean succeeds" {
    run cloudify --on "$TEST_HOST" install digitalocean
    [ "$status" -eq 0 ]
}

@test "doctl binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v doctl'
    [ "$status" -eq 0 ]
}

@test "doctl binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'doctl version'
    [ "$status" -eq 0 ]
}
