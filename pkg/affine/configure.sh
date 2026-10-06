#!/usr/bin/env bash
# affine - run phase (ADR-008 split): converge the running server onto the
# current values. Files only - the server reads all configuration from env
# (config.mjs) plus the optional .linear-api-key file; the sqlite database is
# domain data and is never touched here. No install guard, never destructive:
# an unset AFFINE_LINEAR_API_KEY never deletes an existing key file.

# --- Resolve config (same resolution as install.sh) --------------------------
AFFINE_PORT="${AFFINE_PORT:-8787}"
AFFINE_RATE_LIMIT="${AFFINE_RATE_LIMIT:-100}"
AFFINE_RATE_WINDOW_MS="${AFFINE_RATE_WINDOW_MS:-60000}"
AFFINE_DIR="${AFFINE_DIR:-$HOME/PROJECTS/affine}"
AFFINE_DB="${AFFINE_DB:-$AFFINE_DIR/data/state.db}"
AFFINE_SERVICE="$HOME/.config/systemd/user/affine-mcp.service"
AFFINE_KEY_FILE="$AFFINE_DIR/.linear-api-key"

if ! [[ "$AFFINE_PORT" =~ ^[0-9]+$ ]] || (( AFFINE_PORT < 1 || AFFINE_PORT > 65535 )); then
    die "affine: AFFINE_PORT must be an integer 1-65535 (got '$AFFINE_PORT')"
fi
[[ "$AFFINE_RATE_LIMIT" =~ ^[0-9]+$ ]] || die "affine: AFFINE_RATE_LIMIT must be an integer"
[[ "$AFFINE_RATE_WINDOW_MS" =~ ^[0-9]+$ ]] || die "affine: AFFINE_RATE_WINDOW_MS must be an integer"
[[ -d "$AFFINE_DIR" ]] || die "affine: $AFFINE_DIR missing - run install first (configure never installs)"
[[ -f "$AFFINE_SERVICE" ]] || die "affine: $AFFINE_SERVICE missing - run install first (configure never installs)"
if [[ -n "${AFFINE_LINEAR_API_KEY:-}" ]]; then
    [[ "${AFFINE_LINEAR_API_KEY}" != *"'"* && "${AFFINE_LINEAR_API_KEY}" != *$'\n'* && "${AFFINE_LINEAR_API_KEY}" != *$'\r'* ]] \
        || die "affine: AFFINE_LINEAR_API_KEY contains a single quote or control char - cloudify cannot forward it (see README)"
fi

# --- Converge the unit (rewrite only if changed) ------------------------------
_unit_new="$AFFINE_SERVICE.cloudify-new"
cat > "$_unit_new" << UNITEOF
[Unit]
Description=Affine — clean-room Linear MCP server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$AFFINE_DIR
Environment="PATH=$HOME/.local/share/mise/shims:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="AFFINE_PORT=$AFFINE_PORT"
Environment="AFFINE_RATE_LIMIT=$AFFINE_RATE_LIMIT"
Environment="AFFINE_RATE_WINDOW_MS=$AFFINE_RATE_WINDOW_MS"
Environment="AFFINE_DB=$AFFINE_DB"
ExecStart=$HOME/.local/share/mise/shims/node bin/affine-server.mjs
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=affine-mcp

[Install]
WantedBy=default.target
UNITEOF

if ! cmp -s "$_unit_new" "$AFFINE_SERVICE"; then
    mv "$_unit_new" "$AFFINE_SERVICE" || die "affine: cannot rewrite the unit file"
    log_info "affine: unit updated with current values"
    systemctl --user daemon-reload || die "affine: daemon-reload failed"
else
    rm -f "$_unit_new"
    log_info "affine: unit already current"
fi

# --- Converge the optional Linear compatibility key ---------------------------
# Present key wins; absent var leaves any existing file untouched (never
# destructive - removing a credential is an explicit operator act).
if [[ -n "${AFFINE_LINEAR_API_KEY:-}" ]]; then
    if [[ ! -f "$AFFINE_KEY_FILE" ]] || ! printf '%s\n' "$AFFINE_LINEAR_API_KEY" | cmp -s - "$AFFINE_KEY_FILE"; then
        printf '%s\n' "$AFFINE_LINEAR_API_KEY" > "$AFFINE_KEY_FILE" || die "affine: cannot write the key file"
        chmod 600 "$AFFINE_KEY_FILE"
        log_info "affine: .linear-api-key updated (compatibility door: clients bearing the real Linear key get an anonymous context)"
    fi
elif [[ -f "$AFFINE_KEY_FILE" ]]; then
    log_info "affine: .linear-api-key present but AFFINE_LINEAR_API_KEY unset - left untouched"
fi

# --- Apply + prove ------------------------------------------------------------
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
loginctl enable-linger "$USER" 2>/dev/null || true
systemctl --user restart affine-mcp || die "affine: restart failed"

# A healthy affine answers unauthenticated MCP calls with 401 - brief wait,
# the deep check is verify.sh's job.
_ok=""
for _ in $(seq 1 20); do
    _code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${AFFINE_PORT}/" 2>/dev/null || true)
    [[ "$_code" == "401" ]] && { _ok=1; break; }
    sleep 1
done
[[ -n "$_ok" ]] || { journalctl --user -u affine-mcp -n 20 --no-pager || true; die "affine: no 401 on 127.0.0.1:${AFFINE_PORT} after restart"; }
log_info "affine: converged and answering (401 on :${AFFINE_PORT})"
