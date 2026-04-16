#!/usr/bin/env bats
# Integration test: install emacs-nox package (apt path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install emacs-nox succeeds" {
    run cloudify --on "$TEST_HOST" install emacs-nox
    [ "$status" -eq 0 ]
}

@test "emacs binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v emacs'
    [ "$status" -eq 0 ]
}

@test "emacs binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'emacs --version'
    [ "$status" -eq 0 ]
}
