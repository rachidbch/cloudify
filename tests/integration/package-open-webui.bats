#!/usr/bin/env bats
# Integration test: install open-webui package via SSH

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install open-webui succeeds" {
    run cloudify --on "$TEST_HOST" install open-webui
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'test -f /opt/open-webui/docker-compose.yml'
    [ "$status" -eq 0 ]
}

@test "systemd service is active on $TEST_HOST" {
    # Wait for service to become active (Docker image pull can be slow)
    # Service is "activating" while docker pulls the image, then "active"
    local attempt=0
    local svc_status=""
    while (( attempt < 90 )); do
        svc_status=$($TEST_SSH "root@$TEST_HOST" 'systemctl is-active open-webui' 2>/dev/null || true)
        [[ "$svc_status" == "active" ]] && break
        sleep 2
        attempt=$((attempt + 1))
    done
    [ "$svc_status" = "active" ]
}

@test "docker container is running on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'docker ps --filter name=open-webui --format {{.Status}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Up"* ]]
}

@test "health endpoint responds on $TEST_HOST" {
    # Wait for health endpoint (container may still be starting)
    local attempt=0
    while (( attempt < 60 )); do
        run $TEST_SSH "root@$TEST_HOST" 'curl -sf http://127.0.0.1:3000/health'
        [[ "$status" -eq 0 ]] && break
        sleep 2
        attempt=$((attempt + 1))
    done
    [ "$status" -eq 0 ]
}

@test "data directory exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'test -d /opt/open-webui/data'
    [ "$status" -eq 0 ]
}
