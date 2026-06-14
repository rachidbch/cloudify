#!/usr/bin/env bash
# hermes-dashboard — persistent web dashboard for Hermes Agent
# doc: https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard
#
# Runs the Hermes dashboard via systemd. Two modes:
#   Private (default): 127.0.0.1 — SSH tunnel access
#   Public:            0.0.0.0 --insecure — Tailscale Services / reverse proxy
#
# Config (~/.config/cloudify/pkgs/hermes-dashboard.yaml):
#   HERMES_DASHBOARD_PUBLIC: "true"  → bind 0.0.0.0 --insecure
#
# Architecture:
#   hermes dashboard --no-open --host 127.0.0.1 --port 9119
#   User connects via SSH tunnel (port forwarding)

DASHBOARD_BIND="127.0.0.1"
DASHBOARD_EXTRA=""
if [[ "${HERMES_DASHBOARD_PUBLIC:-}" == "true" ]]; then
    DASHBOARD_BIND="0.0.0.0"
    DASHBOARD_EXTRA="--insecure"
fi

HERMES_DASHBOARD_SERVICE="$HOME/.config/systemd/user/hermes-dashboard.service"

# --- Install guard: skip if already set up unless forced ---
if [[ -f "$HERMES_DASHBOARD_SERVICE" ]] && systemctl --user is-active hermes-dashboard >/dev/null 2>&1 \
   && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "Hermes Dashboard already running. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Dependencies ---
pkg_depends hermes

# --- Create systemd user service ---
mkdir -p "$HOME/.config/systemd/user"
cat > "$HERMES_DASHBOARD_SERVICE" << UNITEOF
[Unit]
Description=Hermes Agent Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.local/bin"
ExecStart=/usr/local/bin/hermes dashboard --no-open --host ${DASHBOARD_BIND} ${DASHBOARD_EXTRA} --port 9119
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hermes-dashboard

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
msg "Dashboard:  http://127.0.0.1:9119 (loopback only — no public exposure)"
msg "Logs:       journalctl --user -u hermes-dashboard -f"
msg "Restart:    systemctl --user restart hermes-dashboard"
msg ""
msg "${YELLOW}Access via SSH tunnel:${RESET}"
msg "  ssh -L 9119:127.0.0.1:9119 $(hostname)"
msg "  Then open http://localhost:9119 in your browser."
msg ""
