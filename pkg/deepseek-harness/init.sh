#!/usr/bin/env bash
# deepseek-harness (dsh) — DeepSeek's agent harness (everything-is-a-plugin, Cordis-powered)
# https://github.com/deepseek-ai/deepseek-harness
#
# Web UI at http://127.0.0.1:3080 (default) — expose via tailscale serve on the
# container for a tailnet HTTPS URL. Runs as a systemd service → survives reboots.
#
# NOTE: developer preview — rapid breaking changes. `npm install -g` pins whatever
# 'latest' is at install time. Re-run install (or `npm update -g @deepseek-ai/dsh`)
# to bump.
#
# Config (~/.config/cloudify/pkgs/deepseek-harness.yaml):
#   (none required — port is fixed at 3080)

DSH_SERVICE="/etc/systemd/system/dsh.service"
DSH_PORT="${DSH_PORT:-3080}"

# Host/Origin the /api browser-trust fence accepts (dsh rejects unknown Hosts
# with 403 — tailscale serve forwards the real hostname). Config override wins;
# else auto-derive the node's tailnet DNS name.
DSH_TRUSTED_HOST="${DSH_TRUSTED_HOST:-}"
if [[ -z "$DSH_TRUSTED_HOST" ]]; then
    DSH_TRUSTED_HOST=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName' 2>/dev/null | sed 's/\.$//')
    [[ "$DSH_TRUSTED_HOST" == "null" ]] && DSH_TRUSTED_HOST=""
fi

# --- Install guard ---
if [[ -f "$DSH_SERVICE" ]] && systemctl is-active dsh >/dev/null 2>&1 \
   && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "dsh already running. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Dependencies: node via mise (house runtime manager) ---
pkg_depends mise
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
mise use -g node@lts

# --- Install dsh (global npm — survives reboots, on-disk) ---
npm install -g @deepseek-ai/dsh || die "dsh: npm install failed"

DSH_BIN="$(command -v dsh || true)"
[[ -n "$DSH_BIN" ]] || die "dsh: binary not found after npm install (is mise node on PATH?)"
log_info "dsh installed at $DSH_BIN"
# mise shims aren't on the non-login ssh PATH — symlink so dsh is callable anywhere
ln -sf "$DSH_BIN" /usr/local/bin/dsh

# --- CLEAR_DATA: stop + wipe service and data dirs ---
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    systemctl stop dsh 2>/dev/null || true
    systemctl disable dsh 2>/dev/null || true
    rm -f "$DSH_SERVICE"
    rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/dsh" "${XDG_DATA_HOME:-$HOME/.local/share}/dsh"
    log_info "dsh data + service cleared."
fi

# --- Systemd service (reboot-surviving) ---
DSH_TRUSTED_ARGS=""
[[ -n "$DSH_TRUSTED_HOST" ]] && DSH_TRUSTED_ARGS=" --trusted-host ${DSH_TRUSTED_HOST}"
cat > "$DSH_SERVICE" << SYSTEMDEOF
[Unit]
Description=DeepSeek Harness (dsh) web UI
After=network.target

[Service]
Type=simple
Environment=PORT=${DSH_PORT}
ExecStart=${DSH_BIN} web --no-open${DSH_TRUSTED_ARGS}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

systemctl daemon-reload
systemctl enable --now dsh

msg ""
msg "${GREEN}dsh installed and running.${RESET}"
msg "  Web UI:  http://127.0.0.1:${DSH_PORT}  (tailscale serve on this node → tailnet URL)"
msg "  Logs:    journalctl -u dsh -f"
msg "  Restart: systemctl restart dsh"
msg ""
