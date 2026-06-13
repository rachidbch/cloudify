#!/usr/bin/env bats
# Integration test: install hermes-dashboard package via SSH
#
# Dashboard runs on 127.0.0.1:9119 (loopback only).
# Access via SSH tunnel: ssh -L 9119:127.0.0.1:9119 <host>

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install hermes-dashboard succeeds" {
    run cloudify --on "$TEST_HOST" install hermes-dashboard
    [ "$status" -eq 0 ]
}

@test "hermes-dashboard systemd service is active on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'systemctl --user is-active hermes-dashboard'
    [ "$status" -eq 0 ]
}

@test "hermes-dashboard serves HTTP 200 on loopback :9119 on $TEST_HOST" {
    # Dashboard may take a moment to start (first launch builds web UI ~27s)
    local attempt=0
    while (( attempt < 45 )); do
        if $TEST_SSH "root@$TEST_HOST" 'curl -sf http://127.0.0.1:9119/' 2>/dev/null >/dev/null; then
            break
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    run $TEST_SSH "root@$TEST_HOST" 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9119/'
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]
}

@test "hermes-dashboard no relay.py left on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'test -f /usr/local/lib/hermes-agent/relay.py && echo "EXISTS" || echo "ABSENT"'
    [ "$status" -eq 0 ]
    [ "$output" = "ABSENT" ]
}
