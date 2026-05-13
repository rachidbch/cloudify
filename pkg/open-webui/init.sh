#!/usr/bin/env bash
# open-webui — Standalone Open WebUI via Docker
# https://github.com/open-webui/open-webui
#
# Runs Open WebUI in Docker as a systemd service.
# Headless admin setup via WEBUI_ADMIN_EMAIL + WEBUI_ADMIN_PASSWORD env vars.
#
# Prerequisites: docker package installed.
#
# Post-install:
#   Access at http://127.0.0.1:<port> with the admin credentials.
#
# Config:
#   CLOUDIFY_OPENWEBUI_PORT  — host port (default: 3000)
#   CLOUDIFY_OPENWEBUI_BIND  — bind address (default: 127.0.0.1, use 0.0.0.0 for Tailscale)
#   WEBUI_ADMIN_EMAIL        — admin email (default: changeme@example.com)
#   WEBUI_ADMIN_PASSWORD     — admin password (default: changeme)
#   OPENAI_API_BASE_URL      — backend URL (optional)
#   OPENAI_API_KEY           — backend API key (optional)
#
# Service management:
#   systemctl status/restart open-webui
#   journalctl -u open-webui -f

OWUI_DIR="/opt/open-webui"
OWUI_PORT="${CLOUDIFY_OPENWEBUI_PORT:-3000}"
OWUI_BIND="${CLOUDIFY_OPENWEBUI_BIND:-127.0.0.1}"
OWUI_ADMIN_EMAIL="${WEBUI_ADMIN_EMAIL:-changeme@example.com}"
OWUI_ADMIN_PASSWORD="${WEBUI_ADMIN_PASSWORD:-changeme}"

# --- Dependencies ---
pkg_depends docker jq
pkg_apt_install curl

# --- Create directories ---
mkdir -p "${OWUI_DIR}/data"

# --- Generate docker-compose.yml ---
cat > "${OWUI_DIR}/docker-compose.yml" <<EOF
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "${OWUI_BIND}:${OWUI_PORT}:8080"
    environment:
      - WEBUI_ADMIN_EMAIL=${OWUI_ADMIN_EMAIL}
      - WEBUI_ADMIN_PASSWORD=${OWUI_ADMIN_PASSWORD}
      - ENABLE_SIGNUP=False
      - BYPASS_MODEL_ACCESS_CONTROL=True
      - ENABLE_OLLAMA_API=False
      - ENABLE_WEBSOCKET_SUPPORT=true
      - OPENAI_API_BASE_URL=${OPENAI_API_BASE_URL:-}
      - OPENAI_API_KEY=${OPENAI_API_KEY:-}
    volumes:
      - ./data:/app/backend/data
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF

# --- Install systemd service ---
cat > /etc/systemd/system/open-webui.service <<EOF
[Unit]
Description=Open WebUI
After=docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=${OWUI_DIR}
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now open-webui

# --- Wait for health endpoint ---
log_info "Waiting for Open WebUI to become healthy..."
max_attempts=30
attempt=0
while (( attempt < max_attempts )); do
    if curl -sf "http://127.0.0.1:${OWUI_PORT}/health" >/dev/null 2>&1; then
        log_info "Open WebUI is healthy."
        break
    fi
    attempt=$((attempt + 1))
    sleep 2
done
if (( attempt >= max_attempts )); then
    log_warn "Open WebUI did not become healthy within 60s. Check: journalctl -u open-webui"
fi

# --- Post-install instructions ---
msg ""
msg "${GREEN}Open WebUI installed and running on port ${OWUI_PORT}.${RESET}"
msg ""
msg "Access:  http://${OWUI_BIND}:${OWUI_PORT}"
msg "Login:   ${OWUI_ADMIN_EMAIL}"
msg ""
msg "Service management:"
msg "  systemctl status open-webui"
msg "  systemctl restart open-webui"
msg "  journalctl -u open-webui -f"
msg ""
msg "Configuration:"
msg "  Edit ${OWUI_DIR}/docker-compose.yml then: systemctl restart open-webui"
msg ""
