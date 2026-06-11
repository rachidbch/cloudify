#!/usr/bin/env bash
# hermes-dashboard — persistent web dashboard for Hermes Agent
# doc: https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard
#
# Runs hermes dashboard as a systemd user service on port 9119.
# Dashboard connects to the existing Hermes gateway (shared ~/.hermes data dir).
# No extra pip install needed — deps already in the hermes venv.

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
cat > "$HERMES_DASHBOARD_SERVICE" << 'UNITEOF'
[Unit]
Description=Hermes Agent Dashboard
Documentation=https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hermes dashboard --no-open --host 127.0.0.1 --port 9119
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
msg "Dashboard:  http://127.0.0.1:9119"
msg "Logs:       journalctl --user -u hermes-dashboard -f"
msg "Restart:    systemctl --user restart hermes-dashboard"
msg ""
