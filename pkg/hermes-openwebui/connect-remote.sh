#!/usr/bin/env bash
# connect-remote.sh — Connect Open WebUI to a remote Hermes agent via MagicDNS
#
# Reads credentials from environment (set via ~/.config/cloudify/credentials):
#   CLOUDIFY_HERMES_API_URL  — e.g. https://hermes.komodo-everest.ts.net/v1
#   CLOUDIFY_HERMES_API_KEY  — Hermes API server key
#
# Updates the Open WebUI docker-compose.yml with the remote backend URL/key,
# then restarts the service. Idempotent — safe to re-run.
#
# Usage: CLOUDIFY_HERMES_API_URL=... CLOUDIFY_HERMES_API_KEY=... /opt/open-webui/connect-remote.sh

set -euo pipefail

OWUI_DIR="/opt/open-webui"
OWUI_COMPOSE="${OWUI_DIR}/docker-compose.yml"

# --- Validate credentials ---
if [[ -z "${CLOUDIFY_HERMES_API_URL:-}" ]]; then
    echo "[ERROR] CLOUDIFY_HERMES_API_URL is not set." >&2
    echo "        Add it to ~/.config/cloudify/credentials:" >&2
    echo "        CLOUDIFY_HERMES_API_URL=https://hermes.komodo-everest.ts.net/v1" >&2
    exit 1
fi

if [[ -z "${CLOUDIFY_HERMES_API_KEY:-}" ]]; then
    echo "[ERROR] CLOUDIFY_HERMES_API_KEY is not set." >&2
    echo "        Add it to ~/.config/cloudify/credentials:" >&2
    echo "        CLOUDIFY_HERMES_API_KEY=sk-..." >&2
    exit 1
fi

# --- Validate docker-compose.yml exists ---
if [[ ! -f "$OWUI_COMPOSE" ]]; then
    echo "[ERROR] $OWUI_COMPOSE not found. Install open-webui first." >&2
    exit 1
fi

# --- Health check remote hermes API ---
echo "[INFO] Checking Hermes API at ${CLOUDIFY_HERMES_API_URL}/health..."
if ! curl -sf --max-time 10 "${CLOUDIFY_HERMES_API_URL}/health" >/dev/null 2>&1; then
    echo "[WARN] Hermes API not reachable at ${CLOUDIFY_HERMES_API_URL}/health" >&2
    echo "       Proceeding anyway — check connectivity if Open WebUI can't connect." >&2
fi

# --- Update docker-compose.yml ---
sed -i "s|OPENAI_API_BASE_URL=.*|OPENAI_API_BASE_URL=${CLOUDIFY_HERMES_API_URL}|" "$OWUI_COMPOSE"
sed -i "s|OPENAI_API_KEY=.*|OPENAI_API_KEY=${CLOUDIFY_HERMES_API_KEY}|" "$OWUI_COMPOSE"
# Ensure RAG embeddings use hermes API (required for separate-containers: no local GPU)
if grep -q "RAG_EMBEDDING_ENGINE=" "$OWUI_COMPOSE"; then
    sed -i 's|RAG_EMBEDDING_ENGINE=.*|RAG_EMBEDDING_ENGINE=openai|' "$OWUI_COMPOSE"
else
    sed -i '/ENABLE_WEBSOCKET_SUPPORT=/a\      - RAG_EMBEDDING_ENGINE=openai' "$OWUI_COMPOSE"
fi

echo "[INFO] Updated $OWUI_COMPOSE with backend URL: ${CLOUDIFY_HERMES_API_URL}"

# --- Restart open-webui service ---
echo "[INFO] Restarting open-webui service..."
systemctl restart open-webui

# --- Wait for health endpoint ---
echo "[INFO] Waiting for Open WebUI to become healthy..."
max_attempts=30
attempt=0
while (( attempt < max_attempts )); do
    owui_port=$(grep -E ':[0-9]+:8080' "$OWUI_COMPOSE" | head -1 | grep -oE '[0-9]+(?=:8080)' || echo "3000")
    [[ -z "$owui_port" ]] && owui_port="3000"

    if curl -sf "http://127.0.0.1:${owui_port}/health" >/dev/null 2>&1; then
        echo "[INFO] Open WebUI is healthy. Connection complete."
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 2
done

echo "[WARN] Open WebUI did not become healthy within 60s. Check: journalctl -u open-webui" >&2
exit 1
