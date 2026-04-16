#!/usr/bin/env bats
# Integration test: install ssh package (apt path — installs autossh) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install ssh succeeds" {
    run cloudify --on "$TEST_HOST" install ssh
    [ "$status" -eq 0 ]
}

@test "autossh binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v autossh'
    [ "$status" -eq 0 ]
}

@test "autossh binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'autossh -V'
    [ "$status" -eq 0 ]
}
