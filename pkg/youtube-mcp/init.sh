#!/usr/bin/env bash
# youtube-mcp — YouTube MCP server (Streamable HTTP transport)
# https://github.com/rachidbch/youtube-mcp
#
# Serves YouTube video info, comments, transcripts, search via MCP protocol.
# No YouTube API key required — uses youtubei.js (InnerTube) + youtube-transcript-plus.
#
# Config (~/.config/cloudify/pkgs/youtube-mcp.yaml):
#   API_TOKEN: "<token>"           — bearer token for MCP endpoint auth
#   YOUTUBE_MCP_PORT: "8443"       — HTTP port (default: 8443)
#
# Post-install:
#   Access MCP endpoint at http://<host>:<port>/mcp
#   Authorization: Bearer <token>
#
# Service management:
#   systemctl status youtube-mcp
#   journalctl -u youtube-mcp -f

MCP_DIR="/opt/youtube-mcp"
MCP_PORT="${YOUTUBE_MCP_PORT:-8443}"
MCP_SERVICE="/etc/systemd/system/youtube-mcp.service"

# --- Install guard ---
if [[ -f "$MCP_SERVICE" ]] && systemctl is-active youtube-mcp >/dev/null 2>&1 \
   && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "youtube-mcp already running. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Dependencies ---
pkg_depends mise git

# --- Ensure Node >=20 via mise ---
# pkg_depends node would skip if apt node exists (FORCE/CLEAR_DATA unset for deps).
# Install directly so mise manages the runtime regardless of existing apt node.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
mise use -g node@lts

# --- Clone/pull source ---
if [[ -d "$MCP_DIR/.git" ]]; then
    log_info "Updating youtube-mcp source..."
    git -C "$MCP_DIR" pull --ff-only
else
    log_info "Cloning youtube-mcp..."
    rm -rf "$MCP_DIR"
    git clone https://github.com/rachidbch/youtube-mcp.git "$MCP_DIR"
fi

# --- Build ---
cd "$MCP_DIR"
log_info "Installing npm dependencies..."
npm install
log_info "Building TypeScript..."
npm run build

# --- Token ---
if [[ -n "${API_TOKEN:-}" ]]; then
    TOKEN="$API_TOKEN"
    log_info "Using API_TOKEN from configuration."
else
    TOKEN=$(openssl rand -hex 32)
    msg ""
    msg "${YELLOW}=== GENERATED API TOKEN — SAVE THIS ===${RESET}"
    msg "  ${TOKEN}"
    msg ""
    msg "Save to ~/.config/cloudify/pkgs/youtube-mcp.yaml:"
    msg "  API_TOKEN: \"${TOKEN}\""
    msg ""
    msg "Without it, --clear-data will generate a new token."
    msg "${YELLOW}=========================================${RESET}"
    msg ""
fi

# --- Systemd service ---
cat > "$MCP_SERVICE" << SYSTEMDEOF
[Unit]
Description=YouTube Transcript MCP Server
After=network.target

[Service]
Type=simple
Environment=PORT=${MCP_PORT}
Environment=API_TOKEN=${TOKEN}
WorkingDirectory=${MCP_DIR}
ExecStart=/root/.local/share/mise/shims/node dist/index.js --http
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

systemctl daemon-reload
systemctl enable --now youtube-mcp

# --- Post-install ---
msg ""
msg "${GREEN}youtube-mcp installed and running.${RESET}"
msg ""
msg "Endpoint: http://$(hostname):${MCP_PORT}/mcp  (replace hostname with IP if needed)"
msg "Logs:     journalctl -u youtube-mcp -f"
msg "Restart:  systemctl restart youtube-mcp"
msg ""
