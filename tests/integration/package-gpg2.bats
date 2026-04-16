#!/usr/bin/env bats
# Integration test: install gpg2 package via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install gpg2 succeeds" {
    run cloudify --on "$TEST_HOST" install gpg2
    [ "$status" -eq 0 ]
}

@test "gpg binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v gpg'
    [ "$status" -eq 0 ]
}

@test "gpg binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'gpg --version'
    [ "$status" -eq 0 ]
}
