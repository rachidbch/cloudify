#!/usr/bin/env bash
# piface — web-based remote interface for pi (the terminal coding agent)
# https://github.com/jbn/piface
#
# Wraps one or more `pi --mode rpc` subprocesses behind a FastAPI + WebSocket
# backend and a Svelte frontend, usable from any browser over Tailscale/VPN.
# The `pi` it drives is @mariozechner/pi-coding-agent (badlogic/pi-mono), NOT the
# host's pi — installed here via npm.
#
# Stack:
#   Node (mise)     → npm install -g @mariozechner/pi-coding-agent  (provides `pi`)
#   uv (standalone) → uv tool install --python 3.12 piface         (PyPI wheel bundles the built
#                                                                    frontend — no node/pnpm build needed)
#   ffmpeg (apt)    → audio conversion for the transcribe endpoint
#
# Runs as a systemd USER service bound to 0.0.0.0:7832. The public bind is safe:
# access is gated at the tailnet (Tailscale Service + ACL grant), not at the host.
#
# Config (~/.config/cloudify/pkgs/piface.yaml):
#   PIFACE_PORT: "7832"      — server port
#   PIFACE_HOST: "0.0.0.0"   — bind address
#
# Post-install:
#   UI:        https://piface.<tailnet>.ts.net  (after ivps expose-service + admin approval)
#   Loopback:  http://127.0.0.1:7832
#   Logs:      journalctl --user -u piface -f
#   Restart:   systemctl --user restart piface
#   Upgrade:   uv tool upgrade piface && systemctl --user restart piface
#
# Note: provider/model API keys for pi are set at runtime via the piface UI or
# pi's own config (~/.pi) — not part of this recipe. Speech/TTS extras are not
# installed (they pull torch + need a GPU); add later with the [speech]/[tts]
# extras on a GPU host if wanted.

PIFACE_PORT="${PIFACE_PORT:-7832}"
PIFACE_HOST="${PIFACE_HOST:-0.0.0.0}"
PIFACE_SERVICE="$HOME/.config/systemd/user/piface.service"

# mise shims + uv bin must be resolvable for the commands below and for the service.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

# --- Install guard -----------------------------------------------------------
if [[ -f "$PIFACE_SERVICE" ]] && systemctl --user is-active piface >/dev/null 2>&1 \
   && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "piface already running. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Dependencies ------------------------------------------------------------
# mise → manages Node for the `pi` agent. git → runtime + pi sessions.
pkg_depends mise git

# Ensure Node LTS (mise-managed). pkg_depends node skips when apt node already
# exists; install directly so the `pi` npm package resolves against a current Node.
mise use -g node@lts

# ffmpeg — audio conversion (documented piface requirement).
pkg_apt_install ffmpeg

# uv (standalone) — installs piface and fetches a managed Python 3.12 itself.
if ! command -v uv >/dev/null 2>&1; then
    log_info "Installing uv (standalone)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# pi agent (the npm CLI piface drives).
if ! command -v pi >/dev/null 2>&1; then
    log_info "Installing pi agent (@mariozechner/pi-coding-agent)..."
    npm install -g @mariozechner/pi-coding-agent
fi

# piface (PyPI wheel bundles the built frontend — no node/pnpm build needed).
# --force so re-runs (FORCE/CLEAR_DATA) refresh the tool env to latest.
log_info "Installing piface (uv tool, Python 3.12)..."
uv tool install --python 3.12 --force piface

# API-key helper: piface's UI only picks provider/model, never stores keys.
# Drop a one-liner that writes pi's auth.json safely (merge + chmod 600).
install -m 0755 "$(dirname "${BASH_SOURCE[0]}")/piface-set-key" "/usr/local/bin/piface-set-key"

# --- systemd user service ----------------------------------------------------
mkdir -p "$HOME/.config/systemd/user"
cat > "$PIFACE_SERVICE" << UNITEOF
[Unit]
Description=Piface — web UI for pi (coding agent)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="PATH=$HOME/.local/share/mise/shims:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=$HOME/.local/bin/piface serve --host ${PIFACE_HOST} --port ${PIFACE_PORT}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=piface

[Install]
WantedBy=default.target
UNITEOF

# Enable linger so the user service survives logout / starts at boot.
loginctl enable-linger "$USER" 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable piface
systemctl --user restart piface

# --- Post-install ------------------------------------------------------------
msg ""
msg "${GREEN}piface installed and running.${RESET}"
msg ""
msg "Loopback: http://127.0.0.1:${PIFACE_PORT}"
msg "Logs:     journalctl --user -u piface -f"
msg "Restart:  systemctl --user restart piface"
msg "Upgrade:  uv tool upgrade piface && systemctl --user restart piface"
msg ""
msg "${YELLOW}Expose on Tailscale:${RESET}"
msg "  ivps expose-service cloudai:piface piface ${PIFACE_PORT} --tags tag:incus"
msg "  then approve svc:piface at https://login.tailscale.com/admin/services"
msg ""
msg "${YELLOW}Configure pi providers:${RESET} set API keys via the piface UI or pi's config (~/.pi)."
msg ""
