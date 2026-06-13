#!/usr/bin/env bats
# Integration test: install hermes-openwebui package (remote hermes mode)
#
# Tests the separate-containers architecture:
#   open-webui (Docker) → MagicDNS → hermes (tailscale serve)
#
# Prerequisites on test container:
#   - open-webui package installed
#   - Tailscale connected (for MagicDNS resolution from Docker)
#
# Credentials are set via environment (no file writes). For e2e tests,
# use ~/.config/cloudify/pkgs/hermes-openwebui.yaml instead.

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# Fake credentials so init.sh takes the remote branch instead of
# falling through to the local (full Hermes install) path.
export CLOUDIFY_HERMES_API_URL=https://hermes.komodo-everest.ts.net/v1
export CLOUDIFY_HERMES_API_KEY=sk-test-fake

# --- Install hermes-openwebui (pulls open-webui as dependency) ---

@test "cloudify --on $TEST_HOST install hermes-openwebui succeeds" {
    run cloudify --on "$TEST_HOST" install hermes-openwebui
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml has MagicDNS backend URL on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'grep -q "OPENAI_API_BASE_URL=https://hermes.komodo-everest.ts.net/v1" /opt/open-webui/docker-compose.yml'
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml has API key on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'grep -q "OPENAI_API_KEY=.\+" /opt/open-webui/docker-compose.yml'
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml has RAG_EMBEDDING_ENGINE=openai on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'grep -q "RAG_EMBEDDING_ENGINE=openai" /opt/open-webui/docker-compose.yml'
    [ "$status" -eq 0 ]
}

@test "open-webui service healthy after remote wiring on $TEST_HOST" {
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
