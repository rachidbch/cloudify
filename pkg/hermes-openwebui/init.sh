#!/usr/bin/env bash
# hermes-openwebui — Connect Open WebUI to a remote Hermes agent via MagicDNS
#
# Architecture (separate containers):
#   openwebui-hermes container: Docker runs Open WebUI
#   hermes container:           Hermes agent + API server (127.0.0.1:8642)
#   Connection: MagicDNS → https://hermes.komodo-everest.ts.net/v1
#
# Prerequisites:
#   - Hermes agent running on a separate container with tailscale serve
#   - Credentials in ~/.config/cloudify/credentials (local machine):
#       CLOUDIFY_HERMES_API_URL=https://hermes.komodo-everest.ts.net/v1
#       CLOUDIFY_HERMES_API_KEY=sk-...
#   - These are passed through the --on remote payload automatically
#
# Idempotent: re-running always regenerates docker-compose.yml from
# current env vars and restarts open-webui.

# --- Remote case: CLOUDIFY_HERMES_API_URL from credentials ---
if [[ -n "${CLOUDIFY_HERMES_API_URL:-}" ]]; then
    # --- Validate credentials ---
    if [[ -z "${CLOUDIFY_HERMES_API_KEY:-}" ]]; then
        die "CLOUDIFY_HERMES_API_URL is set but CLOUDIFY_HERMES_API_KEY is not.\n  Add it to ~/.config/cloudify/credentials:\n  CLOUDIFY_HERMES_API_KEY=sk-..."
    fi

    # --- Export OPENAI_* so open-webui/init.sh picks them up ---
    # open-webui regenerates compose from env vars, restarts, waits for health
    export OPENAI_API_BASE_URL="$CLOUDIFY_HERMES_API_URL"
    export OPENAI_API_KEY="$CLOUDIFY_HERMES_API_KEY"
    pkg_depends open-webui
    pkg_apt_install curl

    # --- Health check hermes API (non-fatal warning) ---
    log_info "Checking Hermes API at ${CLOUDIFY_HERMES_API_URL}/health..."
    if ! curl -sf --max-time 10 "${CLOUDIFY_HERMES_API_URL}/health" >/dev/null 2>&1; then
        log_warn "Hermes API not reachable at ${CLOUDIFY_HERMES_API_URL}/health"
    fi

    # --- Post-install ---
    msg ""
    msg "${GREEN}Hermes-Open WebUI connection established (remote).${RESET}"
    msg ""
    msg "Backend: ${CLOUDIFY_HERMES_API_URL}"
    msg ""
    msg "Access Open WebUI at: https://openwebui-hermes.komodo-everest.ts.net"
    msg "Dashboard:  ssh -L 9119:127.0.0.1:9119 hermes  →  http://localhost:9119"
    msg ""
    msg "To change Hermes credentials, edit ~/.config/cloudify/credentials"
    msg "then re-run: cloudify --on <host> install hermes-openwebui"
    msg ""
    msg "Service management:"
    msg "  systemctl status open-webui"
    msg "  systemctl restart open-webui"
    msg ""
    return 0
fi

# --- Local case (legacy): no CLOUDIFY_HERMES_API_URL set ---
# Hermes and Docker are on the same container. Not the recommended
# architecture, but still supported for backward compatibility.
HERMES_ENV="$HOME/.hermes/.env"

pkg_depends hermes
pkg_apt_install curl

# --- Validate Hermes setup ---
if [[ ! -f "$HERMES_ENV" ]]; then
    die "\$HOME/.hermes/.env not found. Run 'hermes setup' first to configure Hermes."
fi

# --- Read current Hermes API server config ---
get_hermes_var() {
    local key="$1"
    local val
    val=$(grep -E "^${key}=" "$HERMES_ENV" 2>/dev/null | cut -d'=' -f2-)
    val="${val#\"}" ; val="${val%\"}"
    val="${val#\'}" ; val="${val%\'}"
    echo "$val"
}

API_SERVER_ENABLED=$(get_hermes_var "API_SERVER_ENABLED")
API_SERVER_KEY=$(get_hermes_var "API_SERVER_KEY")
API_SERVER_PORT=$(get_hermes_var "API_SERVER_PORT")
API_SERVER_HOST=$(get_hermes_var "API_SERVER_HOST")
needs_restart=false

# --- Enable API server if needed ---
if [[ "$API_SERVER_ENABLED" != "true" ]]; then
    log_info "Enabling Hermes API server in $HERMES_ENV"
    if grep -q "^API_SERVER_ENABLED=" "$HERMES_ENV"; then
        sed -i 's/^API_SERVER_ENABLED=.*/API_SERVER_ENABLED=true/' "$HERMES_ENV"
    else
        echo "API_SERVER_ENABLED=true" >> "$HERMES_ENV"
    fi
    API_SERVER_ENABLED="true"
    needs_restart=true
fi

# --- Generate API key if missing ---
if [[ -z "$API_SERVER_KEY" ]]; then
    log_info "Generating API_SERVER_KEY for Hermes API server"
    API_SERVER_KEY=$(openssl rand -hex 32)
    if grep -q "^API_SERVER_KEY=" "$HERMES_ENV"; then
        sed -i "s|^API_SERVER_KEY=.*|API_SERVER_KEY=${API_SERVER_KEY}|" "$HERMES_ENV"
    else
        echo "API_SERVER_KEY=${API_SERVER_KEY}" >> "$HERMES_ENV"
    fi
    needs_restart=true
fi

# --- Ensure API_SERVER_PORT has a default ---
if [[ -z "$API_SERVER_PORT" ]]; then
    API_SERVER_PORT="8642"
    if grep -q "^API_SERVER_PORT=" "$HERMES_ENV"; then
        sed -i "s/^API_SERVER_PORT=.*/API_SERVER_PORT=${API_SERVER_PORT}/" "$HERMES_ENV"
    else
        echo "API_SERVER_PORT=${API_SERVER_PORT}" >> "$HERMES_ENV"
    fi
    needs_restart=true
fi

# --- Bind to 0.0.0.0 so Docker containers can reach the API server ---
# Default is 127.0.0.1 which is unreachable from Docker bridge (172.17.0.1).
if [[ "$API_SERVER_HOST" != "0.0.0.0" ]]; then
    log_info "Setting API_SERVER_HOST=0.0.0.0 for Docker container access"
    if grep -q "^API_SERVER_HOST=" "$HERMES_ENV"; then
        sed -i 's/^API_SERVER_HOST=.*/API_SERVER_HOST=0.0.0.0/' "$HERMES_ENV"
    else
        echo "API_SERVER_HOST=0.0.0.0" >> "$HERMES_ENV"
    fi
    API_SERVER_HOST="0.0.0.0"
    needs_restart=true
fi

# --- Open firewall for Docker bridge to reach hermes ---
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
    if ! ufw status | grep -q "${API_SERVER_PORT}"; then
        log_info "Opening UFW port ${API_SERVER_PORT} for Docker bridge access"
        ufw allow from 172.16.0.0/12 to any port "${API_SERVER_PORT}" proto tcp
    fi
fi

# --- Install and start Hermes gateway systemd service ---
if ! systemctl --user list-unit-files 2>/dev/null | grep -q "hermes-gateway"; then
    log_info "Installing Hermes gateway as systemd user service..."
    yes | hermes gateway install 2>/dev/null
    loginctl enable-linger "$USER" 2>/dev/null || true
fi

if ! systemctl --user is-active hermes-gateway >/dev/null 2>&1; then
    log_info "Starting Hermes gateway service..."
    systemctl --user start hermes-gateway 2>/dev/null || true
fi

# --- Restart Hermes gateway if config changed ---
if [[ "$needs_restart" == "true" ]]; then
    log_info "Restarting Hermes gateway to apply API server changes..."
    hermes gateway restart 2>/dev/null || systemctl --user restart hermes-gateway 2>/dev/null || log_warn "Could not restart Hermes gateway. Try: hermes gateway restart"
    sleep 3
fi

# --- Export OPENAI_* so open-webui gets correct values first time ---
export OPENAI_API_BASE_URL="http://host.docker.internal:${API_SERVER_PORT}/v1"
export OPENAI_API_KEY="$API_SERVER_KEY"
pkg_depends open-webui

# --- Health check API server (non-fatal warning) ---
log_info "Checking Hermes API at http://127.0.0.1:${API_SERVER_PORT}/health..."
if ! curl -sf --max-time 10 "http://127.0.0.1:${API_SERVER_PORT}/health" >/dev/null 2>&1; then
    log_warn "Hermes API not reachable at http://127.0.0.1:${API_SERVER_PORT}/health"
fi

# --- Post-install ---
msg ""
msg "${GREEN}Hermes-Open WebUI connection established (local).${RESET}"
msg ""
msg "Access:  http://127.0.0.1:\$PORT (check your CLOUDIFY_OPENWEBUI_PORT setting)"
msg "Backend: Hermes API server on port ${API_SERVER_PORT}"
msg ""
msg "Service management:"
msg "  systemctl --user status hermes-gateway"
msg "  systemctl --user restart hermes-gateway"
msg "  systemctl status open-webui"
msg "  systemctl restart open-webui"
msg ""
