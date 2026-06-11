#!/usr/bin/env bats
# Integration test: install hermes-dashboard package via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install hermes-dashboard succeeds" {
    run cloudify --on "$TEST_HOST" install hermes-dashboard
    [ "$status" -eq 0 ]
}

@test "hermes-dashboard systemd service is active on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'systemctl --user is-active hermes-dashboard'
    [ "$status" -eq 0 ]
}

@test "hermes-dashboard relay serves HTTP 200 on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9120/'
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]
}
