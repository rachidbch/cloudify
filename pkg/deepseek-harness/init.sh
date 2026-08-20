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

# --- Dependencies: node via mise (house runtime manager) + pnpm for the plugin ---
# dsh-full-remote (community plugin) provides the authenticated, Host/Origin-
# rewriting proxy on 127.0.0.1:3081 — replaces any manual relay and the
# isLoopback bundle patch (dsh's /api fence is loopback-only by design).
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

# --- dsh-full-remote plugin: token-gated proxy for remote Settings/Models ---
# Solves BOTH gates dsh imposes on remote browsers: the /api Host/Origin fence
# (proxy rewrites both to loopback) and the client isLoopback gate. Adds a
# 192-bit token + per-device sessions. Pin the version; re-audit on upgrades.
corepack enable 2>/dev/null || true
corepack prepare pnpm@latest --activate >/dev/null 2>&1 || true
dsh plugin --profile web add dsh-full-remote@0.3.4 || die "dsh: plugin install failed"

# --- dsh-loopback-pin (our plugin): accessor-based isLoopback pin ---
# dsh-full-remote's page-bootstrap wraps loader.load once — rc.8+ REASSIGNS
# load (thin register arrow), silently clobbering the wrap (marker survives,
# wrapper doesn't) — Settings/Models still fail. Our plugin installs an
# ACCESSOR on loader.load (getter returns our interceptor, setter captures
# reassignments) so the pin survives. Diagnosed live 2026-08-20: all three
# markers fire (accessor installed → module intercepted → isLoopback pinned).
mkdir -p /opt
cp -r "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/dsh-loopback-pin" /opt/ 2>/dev/null \
    || cp -r "${CLOUDIFY_DIR:-$PWD}/pkg/deepseek-harness/dsh-loopback-pin" /opt/ 2>/dev/null \
    || true
[[ -d /opt/dsh-loopback-pin ]] || die "dsh: dsh-loopback-pin source missing"
dsh plugin --profile web add /opt/dsh-loopback-pin || die "dsh: loopback-pin plugin install failed"

# Pre-enable the proxy headlessly (normally via Settings → Reverse proxy):
# state file read at plugin load, restart applies it. Token surfaced to the
# operator for the one-time login.
DSH_PLUGIN_TOKEN="$(openssl rand -hex 32)"
mkdir -p "${DSH_HOME:-$HOME/.dsh}"
cat > "${DSH_HOME:-$HOME/.dsh}/reverse-proxy.json" <<PLUGINEOF
{
  "enabled": true,
  "accessToken": "$DSH_PLUGIN_TOKEN",
  "listenHost": "127.0.0.1",
  "listenPort": 3081
}
PLUGINEOF
chmod 600 "${DSH_HOME:-$HOME/.dsh}/reverse-proxy.json"

msg ""
msg "${YELLOW}=== dsh remote-access token — save this ===${RESET}"
msg "  $DSH_PLUGIN_TOKEN"
msg "  First visit to the tailnet URL shows a login form; enter this token once."
msg "${YELLOW}============================================${RESET}"
msg ""

# --- CLEAR_DATA: stop + wipe service and data dirs ---
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    systemctl stop dsh 2>/dev/null || true
    systemctl disable dsh 2>/dev/null || true
    rm -f "$DSH_SERVICE"
    rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/dsh" "${XDG_DATA_HOME:-$HOME/.local/share}/dsh" "${DSH_HOME:-$HOME/.dsh}"
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

# --- Expose on the tailnet ---
# tailscale serve → 127.0.0.1:3081 → dsh-full-remote proxy (token-gated,
# Host/Origin rewrite) → dsh on 3080.
tailscale serve --https=443 off >/dev/null 2>&1 || true
tailscale serve --bg --https=443 http://127.0.0.1:3081 >/dev/null 2>&1 || true

msg ""
msg "${GREEN}dsh installed and running.${RESET}"
msg "  Web UI:  https://<node>.komodo-everest.ts.net (tailnet, token-gated)"
msg "  Local:   http://127.0.0.1:${DSH_PORT}"
msg "  Logs:    journalctl -u dsh -f"
msg "  Restart: systemctl restart dsh"
msg ""
