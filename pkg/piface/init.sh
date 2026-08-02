#!/usr/bin/env bash
# piface — web UI for pi (terminal coding agent). See README.md.
# Installs @mariozechner/pi-coding-agent (badlogic/pi-mono) as the `pi` it drives,
# which is distinct from the host's pi. Runs as a systemd user service on 0.0.0.0:7832.

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
# mise shims aren't on PATH for non-interactive shells (Debian .bashrc early-returns,
# so `mise activate` never runs for `ssh -t host pi`). Symlink the shim onto the
# base PATH so `pi` resolves everywhere — interactive, non-interactive, systemd.
ln -sf "$HOME/.local/share/mise/shims/pi" /usr/local/bin/pi

# piface (PyPI wheel bundles the built frontend — no node/pnpm build needed).
# --force so re-runs (FORCE/CLEAR_DATA) refresh the tool env to latest.
log_info "Installing piface (uv tool, Python 3.12)..."
uv tool install --python 3.12 --force piface

# API-key helper — non-interactive alternative to pi's `/login` (which needs a
# TTY: `ssh -t root@<host> pi`). /login is preferred; this covers scripts/CI.
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
msg "${YELLOW}Set a provider key (do before first use):${RESET}"
msg "  ssh -t root@$(hostname) pi   →   /login      (interactive; OAuth + API keys)"
msg "  ssh root@$(hostname) piface-set-key --list   (non-interactive: scripts/CI)"
msg ""
msg "${YELLOW}Expose on Tailscale:${RESET} see pkg/piface/README.md. Quickest:"
msg "  ssh root@$(hostname) 'tailscale serve --bg --https 443 http://localhost:${PIFACE_PORT}'"
msg ""
