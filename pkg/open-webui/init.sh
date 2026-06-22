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
#   OPENAI_API_BASE_URL      - backend URL (optional; a *.ts.net URL switches the
#                              container to MagicDNS+public dual-DNS, see init.sh)
#   OPENAI_API_KEY           - backend API key (optional)
#   CLOUDIFY_OPENWEBUI_FALLBACK_DNS - public DNS fallback in MagicDNS mode (default 1.1.1.1)
#
# Service management:
#   systemctl status/restart open-webui
#   journalctl -u open-webui -f

OWUI_DIR="/opt/open-webui"
OWUI_PORT="${CLOUDIFY_OPENWEBUI_PORT:-3000}"
OWUI_BIND="${CLOUDIFY_OPENWEBUI_BIND:-127.0.0.1}"
OWUI_ADMIN_EMAIL="${WEBUI_ADMIN_EMAIL:-changeme@example.com}"
OWUI_ADMIN_PASSWORD="${WEBUI_ADMIN_PASSWORD:-changeme}"

# --- Install guard ---
if command -v docker >/dev/null 2>&1 && [[ -f "${OWUI_DIR}/docker-compose.yml" ]] && \
   [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "Open WebUI already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Clear persistent data if requested ---
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    log_info "Clearing Open WebUI data..."
    rm -rf "${OWUI_DIR}/data"
fi

# --- Dependencies ---
pkg_depends docker jq
pkg_apt_install curl

# --- Create directories ---
mkdir -p "${OWUI_DIR}/data"

# --- Build environment block for docker-compose ---
# Conditionally add RAG_EMBEDDING_ENGINE=openai if an OpenAI backend is configured
env_block=$(cat <<INNER
      - WEBUI_ADMIN_EMAIL=${OWUI_ADMIN_EMAIL}
      - WEBUI_ADMIN_PASSWORD=${OWUI_ADMIN_PASSWORD}
      - ENABLE_SIGNUP=False
      - BYPASS_MODEL_ACCESS_CONTROL=True
      - ENABLE_OLLAMA_API=False
      - ENABLE_WEBSOCKET_SUPPORT=true
      - OPENAI_API_BASE_URL=${OPENAI_API_BASE_URL:-}
      - OPENAI_API_KEY=${OPENAI_API_KEY:-}
INNER
)
env_block+=$'\n'
if [[ -n "${OPENAI_API_BASE_URL:-}" ]]; then
    printf -v env_block '%s      - RAG_EMBEDDING_ENGINE=openai\n' "$env_block"
fi

# --- DNS configuration (topology-dependent) ---
# Two open-webui topologies exist:
#   A) in-container:        backend = host.docker.internal (a host-gateway static entry in
#                           /etc/hosts, NOT a DNS lookup). Container needs only public DNS,
#                           so inherit the host resolver - emit NO dns: directive.
#   B) separate-containers: backend = https://<node>.ts.net. Container must resolve a
#                           Tailscale MagicDNS name, which only 100.100.100.100 (quad100) serves.
#
# Why TWO nameservers in mode B, not just quad100: in this tailnet quad100 resolves
# *.ts.net but SERVFAILs public domains (verified: dig @100.100.100.100 google.com ->
# SERVFAIL; no tailnet global nameservers configured). glibc and musl fail over to the
# next nameserver on SERVFAIL, so ONE resolver block serves BOTH MagicDNS and the public
# internet (huggingface.co for the RAG embedding model, plus telemetry/update checks).
# A tailnet WITH global nameservers would forward public via quad100 itself, making the
# fallback a harmless safety net.
#
# PREREQUISITE (NOT a pkg concern): the container's tailnet node must SEE the backend
# node. MagicDNS only resolves visible peers; an ACL-blocked peer returns NXDOMAIN and no
# dns: directive here can fix that. Fix the Tailscale ACL / node visibility upstream.
OWUI_FALLBACK_DNS="${CLOUDIFY_OPENWEBUI_FALLBACK_DNS:-1.1.1.1}"
dns_block=""
if [[ "${OPENAI_API_BASE_URL:-}" == *".ts.net"* ]]; then
    dns_block=$(printf '    dns:\n      - 100.100.100.100\n      - %s\n' "${OWUI_FALLBACK_DNS}")
fi

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
${env_block}${dns_block}    volumes:
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
ExecStart=/usr/bin/docker compose up --force-recreate
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
max_attempts=120
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
