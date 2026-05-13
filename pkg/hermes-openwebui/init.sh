#!/usr/bin/env bash
# hermes-openwebui — Connect Open WebUI to a Hermes agent
#
# Thin glue package that:
#   1. Ensures Hermes API server is enabled and has an API key
#   2. Copies connect.sh to /opt/open-webui/
#   3. Runs connect.sh to wire the backend URL into Open WebUI
#
# Prerequisites:
#   - hermes package installed and configured (hermes setup completed)
#   - open-webui package installed
#
# Config:
#   ~/.hermes/.env must exist (created by 'hermes setup')
#
# Service management:
#   systemctl status/restart open-webui
#   Reconnect: /opt/open-webui/connect.sh

HERMES_ENV="$HOME/.hermes/.env"

# --- Dependencies ---
pkg_depends hermes open-webui
pkg_apt_install curl

# --- Validate Hermes setup ---
if [[ ! -f "$HERMES_ENV" ]]; then
    die "\$HOME/.hermes/.env not found. Run 'hermes setup' first to configure Hermes."
fi

# --- Read current Hermes API server config ---
# Use grep+cut to avoid sourcing the file (may contain side effects)
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

# --- Restart Hermes gateway if config changed ---
if [[ "$needs_restart" == "true" ]]; then
    log_info "Restarting Hermes gateway to apply API server changes..."
    hermes gateway restart 2>/dev/null || log_warn "Could not restart Hermes gateway automatically. Restart it manually: hermes gateway restart"
    # Give it a moment to start
    sleep 3
fi

# --- Copy and run connect.sh ---
CONNECT_SRC="$(dirname "$(cloudify_package_recipe_path hermes-openwebui)")/connect.sh"
cp "$CONNECT_SRC" "/opt/open-webui/connect.sh"
chmod +x "/opt/open-webui/connect.sh"

log_info "Running connect.sh to wire Open WebUI to Hermes..."
bash "/opt/open-webui/connect.sh"

# --- Post-install instructions ---
msg ""
msg "${GREEN}Hermes-Open WebUI connection established.${RESET}"
msg ""
msg "Access:  http://127.0.0.1:\$PORT (check your CLOUDIFY_OPENWEBUI_PORT setting)"
msg "Backend: Hermes API server on port ${API_SERVER_PORT}"
msg ""
msg "Reconnect after config changes:"
msg "  /opt/open-webui/connect.sh"
msg ""
msg "Service management:"
msg "  systemctl status open-webui"
msg "  systemctl restart open-webui"
msg "  journalctl -u open-webui -f"
msg ""
