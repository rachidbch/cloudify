#!/usr/bin/env bash
# hermes-signal — Signal messaging gateway for Hermes via signal-cli-rest-api
# doc: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/signal
#
# Runs bbernhard/signal-cli-rest-api in Docker as a systemd service.
# Hermes gateway connects to it via HTTP on 127.0.0.1:8080 (SSE + JSON-RPC).
#
# Prerequisites: hermes package installed and configured (API keys, model).
#
# Post-install steps:
#   1. /opt/signal-gateway/link-device.sh   — scan QR to link your phone
#   2. hermes gateway setup                  — select Signal, confirm endpoint
#
# Or in one shot (links phone + configures Hermes):
#   /opt/signal-gateway/link-device.sh --phone +15551234567 --users +15551234567
#   hermes gateway start
#
# Config:
#   CLOUDIFY_SIGNAL_PORT  — API port (default: 8080)
#
# Service management:
#   systemctl status/restart hermes-signal-gateway
#   journalctl -u hermes-signal-gateway -f

GATEWAY_DIR="/opt/signal-gateway"
API_PORT="${CLOUDIFY_SIGNAL_PORT:-8080}"

# --- Dependencies ---
pkg_depends docker jq
pkg_apt_install qrencode curl

# --- Create directories ---
mkdir -p "${GATEWAY_DIR}/data"

# --- Generate docker-compose.yml ---
cat > "${GATEWAY_DIR}/docker-compose.yml" <<EOF
services:
  signal-api:
    image: bbernhard/signal-cli-rest-api:latest
    container_name: hermes-signal-gateway
    restart: unless-stopped
    ports:
      - "127.0.0.1:${API_PORT}:8080"
    environment:
      - MODE=json-rpc
    volumes:
      - ./data:/home/.local/share/signal-cli
EOF

# --- Install systemd service ---
cat > /etc/systemd/system/hermes-signal-gateway.service <<EOF
[Unit]
Description=Signal CLI REST API (for Hermes gateway)
After=docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=${GATEWAY_DIR}
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hermes-signal-gateway

# --- Install link-device helper ---
cp "$(dirname "$(cloudify_package_recipe_path hermes-signal)")/link-device.sh" \
   "${GATEWAY_DIR}/link-device.sh"
chmod +x "${GATEWAY_DIR}/link-device.sh"

# --- Post-install instructions ---
msg ""
msg "${GREEN}Signal gateway installed and running on port ${API_PORT}.${RESET}"
msg ""
msg "Next steps:"
msg "  Link phone + configure Hermes in one shot:"
msg "    ${GATEWAY_DIR}/link-device.sh --phone +15551234567 --users +15551234567"
msg "    hermes gateway start"
msg ""
msg "  Or step by step:"
msg "    1. ${GATEWAY_DIR}/link-device.sh"
msg "    2. hermes gateway setup"
msg ""
msg "Service management:"
msg "  systemctl status hermes-signal-gateway"
msg "  journalctl -u hermes-signal-gateway -f"
msg ""
