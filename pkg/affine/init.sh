#!/usr/bin/env bash
# affine — clean-room Linear MCP server replica (github.com/rachidbch/affine).
# Streamable HTTP MCP server on :8787. On first boot the server mints the
# MASTER token (role 'master', the only credential that can create admin
# users) into data/admin-token.json — this recipe prints it so the operator
# can mint the first admin and store the master offline.
#
# Config (~/.config/cloudify/pkgs/affine.yaml):
#   AFFINE_PORT (default 8787)   AFFINE_DIR (default $HOME/PROJECTS/affine)

AFFINE_PORT="${AFFINE_PORT:-8787}"
AFFINE_DIR="${AFFINE_DIR:-$HOME/PROJECTS/affine}"
AFFINE_SERVICE="$HOME/.config/systemd/user/affine-mcp.service"
AFFINE_TOKEN_FILE="$AFFINE_DIR/data/admin-token.json"

# mise shims + node must be resolvable for the recipe and the service.
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

# --- Install guard -----------------------------------------------------------
if [[ -f "$AFFINE_SERVICE" ]] && systemctl --user is-active affine-mcp >/dev/null 2>&1 \
   && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "affine already running. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Dependencies ---
PKG_DEBUG "REMOTE githubuser set: ${CLOUDIFY_GITHUBUSER:+YES} pwd-len: ${#CLOUDIFY_GITHUBPWD}"---------------------------------------------------------
# git → clone the private repo (the git shadow injects cloudify's GitHub
# credentials). mise → node LTS (Ubuntu's stock node is 18; the server needs
# >= 20.11 for import.meta.dirname, so always use mise, mirroring piface).
pkg_depends git mise
mise use -g node@lts
node --version

# --- Clear data if requested ------------------------------------------------
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    log_info "Clearing affine data (state.db + master token)..."
    rm -rf "$AFFINE_DIR/data"
fi

# --- Source ------------------------------------------------------------------
if [[ ! -d "$AFFINE_DIR/.git" ]]; then
    mkdir -p "$(dirname "$AFFINE_DIR")"
    log_info "Cloning rachidbch/affine (private, cloudify github creds)..."
    git clone --depth 1 https://github.com/rachidbch/affine.git "$AFFINE_DIR"
else
    log_info "affine source present; pulling latest main..."
    git -C "$AFFINE_DIR" pull --ff-only origin main
fi

# --- Dependencies (npm) ------------------------------------------------------
cd "$AFFINE_DIR" || die "affine dir missing: $AFFINE_DIR" 1
npm ci

# --- systemd user service ----------------------------------------------------
mkdir -p "$HOME/.config/systemd/user"
cat > "$AFFINE_SERVICE" << UNITEOF
[Unit]
Description=Affine — clean-room Linear MCP server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$AFFINE_DIR
Environment="PATH=$HOME/.local/share/mise/shims:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="AFFINE_PORT=$AFFINE_PORT"
ExecStart=$HOME/.local/share/mise/shims/node bin/affine-server.mjs
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=affine-mcp

[Install]
WantedBy=default.target
UNITEOF

loginctl enable-linger "$USER" 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable affine-mcp
systemctl --user restart affine-mcp

# --- Wait for first boot + print the MASTER token -----------------------------
# First boot on a fresh data/ mints the master token (role 'master'). Poll the
# token file; then print it so the operator mints the first admin and stores
# the master offline. On --clear-data a NEW master is minted (old one is dead).
for _ in $(seq 1 30); do
    [[ -f "$AFFINE_TOKEN_FILE" ]] && break
    sleep 1
done

if [[ -f "$AFFINE_TOKEN_FILE" ]]; then
    MASTER_TOKEN=$(grep -o '"token": *"[^"]*"' "$AFFINE_TOKEN_FILE" | head -1 | sed 's/.*"token": *"\([^"]*\)"/\1/')
    if [[ -n "$MASTER_TOKEN" ]]; then
        msg ""
        msg "${RED}==============================================================${RESET}"
        msg "${RED}  AFFINE MASTER TOKEN (bootstrap identity, role: master)${RESET}"
        msg "${RED}==============================================================${RESET}"
        msg "  $MASTER_TOKEN"
        msg ""
        msg "${YELLOW}This is the ONLY credential that can create admin users.${RESET}"
        msg "1. Mint the first admin NOW:  create_user { name: <admin>, role: \"admin\" }"
        msg "2. Store THIS master token in a secure place (e.g. printed in a safe)."
        msg "3. Do not use it again except in emergencies (leaked-admin recovery)."
        msg "On --clear-data reinstall a NEW master is minted; the old one dies."
        msg "Token file: $AFFINE_TOKEN_FILE (0600)"
        msg ""
    else
        msg "${YELLOW}admin-token.json present but unreadable; see journalctl --user -u affine-mcp${RESET}"
    fi
else
    msg "${YELLOW}Master token file not found yet; see journalctl --user -u affine-mcp${RESET}"
fi

# --- Post-install ------------------------------------------------------------
msg ""
msg "${GREEN}affine MCP server running on http://0.0.0.0:${AFFINE_PORT}/mcp${RESET}"
msg "Logs:   journalctl --user -u affine-mcp -f"
msg "Docs:   $AFFINE_DIR/PRD.md, ADR.md, ROADMAP.md"
msg ""
