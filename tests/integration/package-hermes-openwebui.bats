#!/usr/bin/env bats
# Integration test: install hermes-openwebui package via SSH
#
# Uses KeylessAI (https://keylessai.thryx.workers.dev) as a free,
# keyless LLM endpoint for Hermes. Aggregates Pollinations + ApiAirforce
# with auto-failover. No API key, no account, no credit card.
# See "Testing Docker & AI Packages" in README.md for details.

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# --- Test fixture: install hermes + configure with keyless LLM ---

@test "hermes package installed on $TEST_HOST" {
    run cloudify --on "$TEST_HOST" install hermes
    [ "$status" -eq 0 ]
}

@test "hermes configured with keyless Pollinations endpoint on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'mkdir -p ~/.hermes && cat > ~/.hermes/.env <<EOF
API_SERVER_ENABLED=true
API_SERVER_HOST=0.0.0.0
API_SERVER_PORT=8642
API_SERVER_KEY=test-integration-key
EOF'
    [ "$status" -eq 0 ]

    run $TEST_SSH "root@$TEST_HOST" 'cat > ~/.hermes/config.yaml <<EOF
model: openai-fast
provider: custom
base_url: https://keylessai.thryx.workers.dev/v1
EOF'
    [ "$status" -eq 0 ]
}

@test "hermes gateway started on $TEST_HOST" {
    # Start gateway in background and wait for API server health
    $TEST_SSH "root@$TEST_HOST" 'nohup hermes gateway > /tmp/hermes-gateway.log 2>&1 &'

    # Wait up to 30s for the API server health endpoint
    local attempt=0
    while (( attempt < 30 )); do
        if $TEST_SSH "root@$TEST_HOST" 'curl -sf http://127.0.0.1:8642/health' >/dev/null 2>&1; then
            break
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    run $TEST_SSH "root@$TEST_HOST" 'curl -sf http://127.0.0.1:8642/health'
    [ "$status" -eq 0 ]
}

# --- Install open-webui (prerequisite) ---

@test "open-webui installed on $TEST_HOST" {
    run cloudify --on "$TEST_HOST" install open-webui
    [ "$status" -eq 0 ]
}

# --- Install hermes-openwebui and verify wiring ---

@test "cloudify --on $TEST_HOST install hermes-openwebui succeeds" {
    run cloudify --on "$TEST_HOST" install hermes-openwebui
    [ "$status" -eq 0 ]
}

@test "connect.sh installed on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'test -x /opt/open-webui/connect.sh'
    [ "$status" -eq 0 ]
}

@test "API_SERVER_ENABLED is true in hermes env on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'grep -q "^API_SERVER_ENABLED=true" ~/.hermes/.env'
    [ "$status" -eq 0 ]
}

@test "API_SERVER_HOST is 0.0.0.0 in hermes env on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'grep -q "^API_SERVER_HOST=0.0.0.0" ~/.hermes/.env'
    [ "$status" -eq 0 ]
}

@test "API_SERVER_KEY is set in hermes env on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'grep -q "^API_SERVER_KEY=.\+" ~/.hermes/.env'
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml has hermes backend URL on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'grep -q "OPENAI_API_BASE_URL=http://host.docker.internal:8642/v1" /opt/open-webui/docker-compose.yml'
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml has API key on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'grep -q "OPENAI_API_KEY=" /opt/open-webui/docker-compose.yml'
    [ "$status" -eq 0 ]
}

@test "Docker container can reach hermes API on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'docker exec open-webui curl -sf --max-time 5 http://host.docker.internal:8642/v1/models -H "Authorization: Bearer test-integration-key"'
    [ "$status" -eq 0 ]
}

@test "open-webui service still healthy after wiring on $TEST_HOST" {
    # Wait for health after the restart
    local attempt=0
    while (( attempt < 30 )); do
        if $TEST_SSH "root@$TEST_HOST" 'curl -sf http://127.0.0.1:3000/health' >/dev/null 2>&1; then
            break
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    run $TEST_SSH "root@$TEST_HOST" 'curl -sf http://127.0.0.1:3000/health'
    [ "$status" -eq 0 ]
}
