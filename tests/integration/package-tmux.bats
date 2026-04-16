#!/usr/bin/env bats
# Integration test: install tmux package (apt path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install tmux succeeds" {
    run cloudify --on "$TEST_HOST" install tmux
    [ "$status" -eq 0 ]
}

@test "tmux binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v tmux'
    [ "$status" -eq 0 ]
}

@test "tmux binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'tmux -V'
    [ "$status" -eq 0 ]
}
