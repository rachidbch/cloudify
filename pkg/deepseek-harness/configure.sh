#!/usr/bin/env bash
# deepseek-harness (dsh) — update phase (ADR-008 split; ADR-014).
# Runs unguarded via `cloudify configure deepseek-harness`: bumps dsh to the
# npm latest, re-applies the plugins, refreshes the systemd unit, restarts.
# Preserves the remote-access token, device sessions, and all state by
# construction — ~/.dsh, ~/.config/dsh, ~/.local/share/dsh are never touched.
# The verification hook (ADR-004) runs after configure and gates the update.

DSH_SERVICE="/etc/systemd/system/dsh.service"
DSH_PORT="${DSH_PORT:-3080}"

# Sanity: the update path assumes an existing install.
if ! command -v dsh >/dev/null 2>&1; then
    die "dsh: binary not found — nothing to update. Run: cloudify install deepseek-harness"
fi

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
mise use -g node@lts 2>/dev/null || true

# Previous version for the rollback hint (verify failure = gate fail).
PREV="$(npm ls -g @deepseek-ai/dsh 2>/dev/null | grep -oE '@deepseek-ai/dsh@[^ ]+' | head -1 || true)"

# --- Bump to npm latest (no-op when already latest) ---
npm install -g @deepseek-ai/dsh || die "dsh: npm update failed"
NEW="$(npm ls -g @deepseek-ai/dsh 2>/dev/null | grep -oE '@deepseek-ai/dsh@[^ ]+' | head -1)"

# Re-resolve the binary + stable symlink (a mise node-version move may have
# changed the install path — the unit references the symlink, never the path).
DSH_BIN="$(command -v dsh || true)"
[[ -n "$DSH_BIN" ]] || die "dsh: binary not found after npm update"
ln -sf "$DSH_BIN" /usr/local/bin/dsh

# --- Re-apply plugins (idempotent: 'added 0' when already present) ---
corepack enable 2>/dev/null || true
corepack prepare pnpm@latest --activate >/dev/null 2>&1 || true
dsh plugin --profile web add dsh-full-remote@0.3.4 || die "dsh: plugin install failed"
[[ -d /opt/dsh-loopback-pin ]] || die "dsh: /opt/dsh-loopback-pin missing (run install first)"
dsh plugin --profile web add /opt/dsh-loopback-pin || die "dsh: loopback-pin plugin install failed"

# --- Unit refresh: same Host/Origin trust derivation as install.sh ---
DSH_TRUSTED_HOST="${DSH_TRUSTED_HOST:-}"
if [[ -z "$DSH_TRUSTED_HOST" ]]; then
    DSH_TRUSTED_HOST=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName' 2>/dev/null | sed 's/\.$//')
    [[ "$DSH_TRUSTED_HOST" == "null" ]] && DSH_TRUSTED_HOST=""
fi
DSH_TRUSTED_ARGS=""
[[ -n "$DSH_TRUSTED_HOST" ]] && DSH_TRUSTED_ARGS=" --trusted-host ${DSH_TRUSTED_HOST}"

cat > "$DSH_SERVICE" << SYSTEMDEOF
[Unit]
Description=DeepSeek Harness (dsh) web UI
After=network.target

[Service]
Type=simple
Environment=PORT=${DSH_PORT}
ExecStart=/usr/local/bin/dsh web --no-open${DSH_TRUSTED_ARGS}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMDEOF
systemctl daemon-reload
systemctl restart dsh

msg ""
msg "${GREEN}dsh updated: ${PREV:-<none>} -> ${NEW}${RESET}"
msg "  Token + sessions preserved: ${DSH_HOME:-$HOME/.dsh}/reverse-proxy.json"
msg "  Rollback if this update misbehaves: npm install -g ${PREV:-@deepseek-ai/dsh} && systemctl restart dsh"
msg ""
