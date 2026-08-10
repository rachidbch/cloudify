#!/usr/bin/env bats
# Integration test: affine MCP server package (private-repo clone + master token)

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install affine succeeds" {
    run cloudify --on "$TEST_HOST" install affine
    [ "$status" -eq 0 ]
}

@test "affine service is active on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'systemctl --user is-active affine-mcp'
    [ "$status" -eq 0 ]
    [ "$output" = "active" ]
}

@test "affine source cloned on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'test -f /root/PROJECTS/affine/bin/affine-server.mjs'
    [ "$status" -eq 0 ]
}

@test "master token file exists and is 0600 on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'stat -c "%a" /root/PROJECTS/affine/data/admin-token.json'
    [ "$status" -eq 0 ]
    [ "$output" = "600" ]
}

@test "unauthenticated POST /mcp answers 401 on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}" http://127.0.0.1:8787/mcp); echo "$code"'
    [ "$status" -eq 0 ]
    [ "$output" = "401" ]
}
