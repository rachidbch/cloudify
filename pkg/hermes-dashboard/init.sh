#!/usr/bin/env bash
# hermes-dashboard — persistent web dashboard for Hermes Agent
# doc: https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard
#
# Runs a Host-header-rewriting relay (port 9120) that proxies to the
# dashboard (port 9119, loopback). The relay is a WORKAROUND for missing
# --allowed-hosts flag in Hermes (hermes-agent#34390). When that lands,
# the relay can be removed and tailscale serve pointed directly at 9119.
#
# Architecture:
#   tailscale serve :443 → relay :9120 → dashboard :9119 (loopback)

HERMES_VENV="/usr/local/lib/hermes-agent/venv"
RELAY_SRC="$(dirname "$(cloudify_package_recipe_path hermes-dashboard)")/relay.py"
RELAY_DST="/usr/local/lib/hermes-agent/relay.py"
HERMES_DASHBOARD_SERVICE="$HOME/.config/systemd/user/hermes-dashboard.service"

# --- Install guard: skip if already set up unless forced ---
if [[ -f "$HERMES_DASHBOARD_SERVICE" ]] && systemctl --user is-active hermes-dashboard >/dev/null 2>&1 \
   && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "Hermes Dashboard already running. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Dependencies ---
pkg_depends hermes

# --- Install Host-header-rewriting relay ---
cp "$RELAY_SRC" "$RELAY_DST"

# --- Create systemd user service ---
mkdir -p "$HOME/.config/systemd/user"
cat > "$HERMES_DASHBOARD_SERVICE" << UNITEOF
[Unit]
Description=Hermes Agent Dashboard (with Host-header relay)
Documentation=https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${HERMES_VENV}/bin/python3 ${RELAY_DST}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hermes-dashboard

# Hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
UNITEOF

# Enable linger so user service survives logout
loginctl enable-linger "$USER" 2>/dev/null || true

# Reload and start
systemctl --user daemon-reload
systemctl --user enable hermes-dashboard
systemctl --user start hermes-dashboard

# --- Post-install ---
msg ""
msg "${GREEN}Hermes Dashboard installed and running.${RESET}"
msg ""
msg "Relay:      127.0.0.1:9120 → dashboard :9119 (Host header rewritten)"
msg "Dashboard:  http://127.0.0.1:9119 (loopback only)"
msg "Logs:       journalctl --user -u hermes-dashboard -f"
msg "Restart:    systemctl --user restart hermes-dashboard"
msg ""
msg "${YELLOW}To expose via Tailscale:${RESET}"
msg "  ivps expose-direct <node>:hermes 9120 --path /dashboard"
msg ""
msg "${YELLOW}WORKAROUND:${RESET} relay.py rewrites Host header for tailscale serve."
msg "Remove when --allowed-hosts lands (hermes-agent#34390)."
msg ""
