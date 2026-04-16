#!/usr/bin/env bats
# Integration test: install paping package (curl + tar path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install paping succeeds" {
    run cloudify --on "$TEST_HOST" install paping
    [ "$status" -eq 0 ]
}

@test "paping binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v paping'
    [ "$status" -eq 0 ]
}

@test "paping binary runs on $TEST_HOST" {
    # paping exits 200 on --version (usage), which confirms the binary works
    run $TEST_SSH "root@$TEST_HOST" 'paping --version; exit $(( $? == 200 ? 0 : 1 ))'
    [ "$status" -eq 0 ]
}
