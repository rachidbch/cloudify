#!/usr/bin/env bash
# octop - run phase (ADR-008 split): converge the running assistant onto the
# current values. Files only: OCTOP_PORT/OCTOP_BIND_HOST/OCTOP_LOG_LEVEL are
# upserted into $OCTOP_HOME/env (the dotenv the server itself loads at start;
# env overrides config.json). Foreign keys in the env file (dashboard-set API
# keys etc.) are preserved - upsert, never replace. The systemd unit is
# Octop-owned (`octop service`); this phase never rewrites it, only restarts.
# Never destructive: an unset knob leaves any existing line untouched.

OCTOP_PORT="${OCTOP_PORT:-8088}"
OCTOP_BIND_HOST="${OCTOP_BIND_HOST:-127.0.0.1}"
OCTOP_LOG_LEVEL="${OCTOP_LOG_LEVEL:-info}"
OCTOP_HOME="${OCTOP_HOME:-$HOME/.octop}"
OCTOP_BIN="$OCTOP_HOME/bin/octop"
export PATH="$OCTOP_HOME/bin:$PATH"

# --- Validate -----------------------------------------------------------------
if ! [[ "$OCTOP_PORT" =~ ^[0-9]+$ ]] || (( OCTOP_PORT < 1 || OCTOP_PORT > 65535 )); then
    die "octop: OCTOP_PORT must be an integer 1-65535 (got '$OCTOP_PORT')"
fi
[[ "$OCTOP_LOG_LEVEL" =~ ^(debug|info|warning|error)$ ]] \
    || die "octop: OCTOP_LOG_LEVEL must be one of debug|info|warning|error (got '$OCTOP_LOG_LEVEL')"
[[ "$OCTOP_BIND_HOST" =~ ^[0-9a-zA-Z._-]+$ ]] \
    || die "octop: OCTOP_BIND_HOST must be an IP or hostname without spaces/specials (got '$OCTOP_BIND_HOST')"
[[ -x "$OCTOP_BIN" ]] || die "octop: $OCTOP_BIN missing - run install first (configure never installs)"
[[ -f "$OCTOP_HOME/octop.db" ]] || die "octop: $OCTOP_HOME/octop.db missing - run install first (configure never installs)"
[[ -f "$OCTOP_HOME/env" ]] || die "octop: $OCTOP_HOME/env missing - run install first (configure never installs)"

# --- Converge the env file (upsert ours, keep foreign keys) --------------------
_changed=0
_upsert() {
    local key="$1" value="$2" file="$OCTOP_HOME/env" current
    current=$(grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)
    if [[ "$current" == "$value" ]]; then
        log_info "octop: $key already $value"
        return 0
    fi
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file" || die "octop: cannot rewrite $key in env file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file" || die "octop: cannot append $key to env file"
    fi
    _changed=1
    log_info "octop: $key -> $value"
}
chmod 600 "$OCTOP_HOME/env"
_upsert OCTOP_PORT "$OCTOP_PORT"
_upsert OCTOP_BIND_HOST "$OCTOP_BIND_HOST"
_upsert OCTOP_LOG_LEVEL "$OCTOP_LOG_LEVEL"

# --- Apply + prove --------------------------------------------------------------
loginctl enable-linger "$USER" 2>/dev/null || true
if [[ "$_changed" == "1" ]]; then
    export OCTOP_SERVICE_SCOPE=user
    "$OCTOP_BIN" service restart || die "octop: 'octop service restart' failed - see journalctl --user -u octop"
else
    log_info "octop: env already converged - restart not needed"
    "$OCTOP_BIN" service status >/dev/null 2>&1 || "$OCTOP_BIN" service start || die "octop: service not running and start failed"
fi
systemctl --user is-active octop >/dev/null 2>&1 || die "octop: service not active after configure"

_ok=""
for _ in $(seq 1 30); do
    _body=$(curl -s --max-time 3 "http://127.0.0.1:${OCTOP_PORT}/health" 2>/dev/null || true)
    [[ "$_body" == *'"status": "ok"'* || "$_body" == *'"status":"ok"'* ]] && { _ok=1; break; }
    sleep 2
done
[[ -n "$_ok" ]] || { journalctl --user -u octop -n 20 --no-pager || true; die "octop: no healthy /health on 127.0.0.1:${OCTOP_PORT} after configure"; }
log_info "octop: converged and healthy (/:${OCTOP_PORT} on ${OCTOP_BIND_HOST})"
