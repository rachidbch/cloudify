#!/usr/bin/env bats
# Integration test: install lazygit package (GitHub release path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install lazygit succeeds" {
    run cloudify --on "$TEST_HOST" install lazygit
    [ "$status" -eq 0 ]
}

@test "lazygit binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v lazygit'
    [ "$status" -eq 0 ]
}

@test "lazygit binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'lazygit --version'
    [ "$status" -eq 0 ]
}
