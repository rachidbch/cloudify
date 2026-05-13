#!/usr/bin/env bash
# connect.sh — Connect Open WebUI to a Hermes agent
#
# Reads Hermes config from ~/.hermes/.env, updates the Open WebUI
# docker-compose.yml with the backend URL/key, and restarts the service.
#
# Idempotent — safe to re-run.
#
# Usage: /opt/open-webui/connect.sh

set -euo pipefail

HERMES_ENV="$HOME/.hermes/.env"
OWUI_DIR="/opt/open-webui"
OWUI_COMPOSE="${OWUI_DIR}/docker-compose.yml"

# --- Read Hermes config (without sourcing — use grep+cut) ---
if [[ ! -f "$HERMES_ENV" ]]; then
    echo "[ERROR] $HERMES_ENV not found. Run 'hermes setup' first." >&2
    exit 1
fi

get_hermes_var() {
    local key="$1"
    local val
    val=$(grep -E "^${key}=" "$HERMES_ENV" 2>/dev/null | cut -d'=' -f2-)
    # Strip surrounding quotes if present
    val="${val#\"}" ; val="${val%\"}"
    val="${val#\'}" ; val="${val%\'}"
    echo "$val"
}

API_SERVER_ENABLED=$(get_hermes_var "API_SERVER_ENABLED")
API_SERVER_KEY=$(get_hermes_var "API_SERVER_KEY")
API_SERVER_PORT=$(get_hermes_var "API_SERVER_PORT")

# --- Validate ---
if [[ -z "$API_SERVER_PORT" ]]; then
    echo "[ERROR] API_SERVER_PORT not set in $HERMES_ENV." >&2
    exit 1
fi

if [[ "$API_SERVER_ENABLED" != "true" ]]; then
    echo "[WARN] Hermes API server is not enabled. Run 'hermes-openwebui' install first or enable it in $HERMES_ENV." >&2
    exit 1
fi

# --- Check Hermes API server health ---
echo "[INFO] Checking Hermes API server at http://127.0.0.1:${API_SERVER_PORT}/health..."
if ! curl -sf "http://127.0.0.1:${API_SERVER_PORT}/health" >/dev/null 2>&1; then
    echo "[ERROR] Hermes API server not responding on port ${API_SERVER_PORT}." >&2
    echo "        Start it with: hermes gateway start" >&2
    exit 1
fi
echo "[INFO] Hermes API server is healthy."

# --- Update docker-compose.yml ---
if [[ ! -f "$OWUI_COMPOSE" ]]; then
    echo "[ERROR] $OWUI_COMPOSE not found. Install open-webui first." >&2
    exit 1
fi

BACKEND_URL="http://host.docker.internal:${API_SERVER_PORT}/v1"

# Replace OPENAI_API_BASE_URL and OPENAI_API_KEY lines
sed -i "s|OPENAI_API_BASE_URL=.*|OPENAI_API_BASE_URL=${BACKEND_URL}|" "$OWUI_COMPOSE"
sed -i "s|OPENAI_API_KEY=.*|OPENAI_API_KEY=${API_SERVER_KEY}|" "$OWUI_COMPOSE"

echo "[INFO] Updated $OWUI_COMPOSE with backend URL: ${BACKEND_URL}"

# --- Restart open-webui service ---
echo "[INFO] Restarting open-webui service..."
systemctl restart open-webui

# --- Wait for health endpoint ---
echo "[INFO] Waiting for Open WebUI to become healthy..."
max_attempts=30
attempt=0
while (( attempt < max_attempts )); do
    # Determine the port from docker-compose.yml
    owui_port=$(grep -E '127\.0\.0\.1:[0-9]+' "$OWUI_COMPOSE" | head -1 | grep -oE '[0-9]+(?=:8080)' || echo "3000")
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
