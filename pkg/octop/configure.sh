#!/usr/bin/env bash
# octop - run phase (ADR-008 split): converge the running assistant onto the
# current values. Files only: OCTOP_PORT/OCTOP_BIND_HOST/OCTOP_LOG_LEVEL are
# merged into $OCTOP_HOME/config.json (jq read-merge-write; foreign keys
# preserved). config.json - NOT the env file - is the bind truth: `octop run`
# resolves CLI flag > process env > config.json and applies ~/.octop/env only
# after binding, so env-file OCTOP_PORT would be silently ignored under
# systemd (upstream: env_bind_overrides precedes OctopServer.start).
# The systemd unit is Octop-owned (`octop service`); this phase never
# rewrites it, only restarts. Never destructive: an unset knob is not
# written; foreign config keys survive byte-for-byte.

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
[[ -f "$OCTOP_HOME/config.json" ]] || die "octop: $OCTOP_HOME/config.json missing - run install first (configure never installs)"
# NOTE: no octop.db precondition - the database materializes only after the
# first-run setup wizard completes; converging config + restart on a
# pre-setup server is safe (the one-time wizard password self-heals).

# --- Converge config.json (jq read-merge-write; foreign keys untouched) ---------
_config="$OCTOP_HOME/config.json"
_changed=0
_cur_p=$(jq -r '.port // empty' "$_config" 2>/dev/null)
_cur_h=$(jq -r '.bind_host // empty' "$_config" 2>/dev/null)
_cur_l=$(jq -r '.log_level // empty' "$_config" 2>/dev/null)
if [[ "$_cur_p" == "$OCTOP_PORT" && "$_cur_h" == "$OCTOP_BIND_HOST" && "$_cur_l" == "$OCTOP_LOG_LEVEL" ]]; then
    log_info "octop: config.json already converged (bind ${OCTOP_BIND_HOST}:${OCTOP_PORT}, log ${OCTOP_LOG_LEVEL})"
else
    _tmp="$_config.cloudify-new"
    jq --arg h "$OCTOP_BIND_HOST" --argjson p "$OCTOP_PORT" --arg l "$OCTOP_LOG_LEVEL" \
        '.bind_host=$h | .port=$p | .log_level=$l' "$_config" > "$_tmp" \
        || die "octop: cannot merge $_config (corrupt json?)"
    mv "$_tmp" "$_config" || die "octop: cannot rewrite $_config"
    _changed=1
    log_info "octop: config.json -> bind ${OCTOP_BIND_HOST}:${OCTOP_PORT}, log ${OCTOP_LOG_LEVEL} (was ${_cur_h:-unset}:${_cur_p:-unset}, ${_cur_l:-unset})"
fi

# --- Apply + prove --------------------------------------------------------------
loginctl enable-linger "$USER" 2>/dev/null || true
if [[ "$_changed" == "1" ]]; then
    export OCTOP_SERVICE_SCOPE=user
    "$OCTOP_BIN" service restart || die "octop: 'octop service restart' failed - see journalctl --user -u octop"
else
    log_info "octop: config already converged - restart not needed"
    "$OCTOP_BIN" service status >/dev/null 2>&1 || "$OCTOP_BIN" service start || die "octop: service not running and start failed"
fi
systemctl --user is-active octop >/dev/null 2>&1 || die "octop: service not active after configure"

_ok=""
for _ in $(seq 1 90); do
    _body=$(curl -s --max-time 3 "http://127.0.0.1:${OCTOP_PORT}/api/health" 2>/dev/null || true)
    [[ "$_body" == *'"ok":true'* ]] && { _ok=1; break; }
    sleep 2
done
[[ -n "$_ok" ]] || { journalctl --user -u octop -n 20 --no-pager || true; die "octop: no healthy /api/health on 127.0.0.1:${OCTOP_PORT} after configure"; }
log_info "octop: converged and healthy (/api/health on :${OCTOP_PORT}, bind ${OCTOP_BIND_HOST})"
