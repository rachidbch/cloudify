#!/usr/bin/env bats
# Integration test: install neovim package (apt path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install neovim succeeds" {
    run cloudify --on "$TEST_HOST" install neovim
    [ "$status" -eq 0 ]
}

@test "nvim binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v nvim'
    [ "$status" -eq 0 ]
}

@test "nvim binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'nvim --version'
    [ "$status" -eq 0 ]
}
