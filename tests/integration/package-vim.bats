#!/usr/bin/env bats
# Integration test: install vim package (apt path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install vim succeeds" {
    run cloudify --on "$TEST_HOST" install vim
    [ "$status" -eq 0 ]
}

@test "vim binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v vim'
    [ "$status" -eq 0 ]
}

@test "vim binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'vim --version'
    [ "$status" -eq 0 ]
}
