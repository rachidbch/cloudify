#!/usr/bin/env bats
# Integration test: install paping package (now tcping-rs) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install paping succeeds" {
    run cloudify --on "$TEST_HOST" install paping
    [ "$status" -eq 0 ]
}

@test "tcping binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v tcping'
    [ "$status" -eq 0 ]
}

@test "tcping binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'tcping --version'
    [ "$status" -eq 0 ]
}
