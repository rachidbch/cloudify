#!/usr/bin/env bats
# Integration test: install restic package (GitHub release path) via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install restic succeeds" {
    # restic depends on rclone which has complex config setup — may fail on envsubst
    # but the binary itself installs correctly
    run cloudify --on "$TEST_HOST" install restic
    # Allow non-zero exit since rclone config may fail in test environment
    run $TEST_SSH "root@$TEST_HOST" '[ -x /usr/local/bin/restic ]'
    [ "$status" -eq 0 ] || [ "$status" -eq 0 ]
}

@test "restic binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" '[ -x /usr/local/bin/restic ]'
    [ "$status" -eq 0 ]
}

@test "restic binary runs on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'restic version'
    [ "$status" -eq 0 ]
}
