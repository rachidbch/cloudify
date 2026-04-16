#!/usr/bin/env bats
# Integration test: install pandoc package (GitHub release path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install pandoc succeeds" {
    run cloudify --on "$TEST_HOST" install pandoc
    [ "$status" -eq 0 ]
}

@test "pandoc binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v pandoc'
    [ "$status" -eq 0 ]
}

@test "pandoc binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'pandoc --version'
    [ "$status" -eq 0 ]
}
