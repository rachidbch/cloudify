#!/usr/bin/env bats
# Integration test: install entr package (apt path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install entr succeeds" {
    run cloudify --on "$TEST_HOST" install entr
    [ "$status" -eq 0 ]
}

@test "entr binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v entr'
    [ "$status" -eq 0 ]
}

@test "entr binary runs on $TEST_HOST" {
    # entr exits non-zero when run without arguments (expected)
    run $TEST_SSH "root@$TEST_HOST" 'entr'
    [ "$status" -ne 0 ]
}
