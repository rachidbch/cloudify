#!/usr/bin/env bash
# t3code - configure phase (ADR-008 split): converge the running install onto
# the requested channel/version. Create-if-absent belongs to install.sh; this
# phase re-runs the vendor installer (idempotent: "already downloaded" when
# current), re-registers the service (repair + unit re-pinned to the linked
# version) and restarts only when the linked binary moved.
#
# Config: same names as install.sh (T3CODE_CHANNEL, T3CODE_VERSION, T3CODE_USER,
# T3CODE_PORT). Upstream update path: the installer downloads the newest release
# on the channel; `t3 service restart` picks it up ("restart-pending").

T3CODE_CHANNEL="${T3CODE_CHANNEL:-nightly}"
T3CODE_VERSION="${T3CODE_VERSION:-}"
T3CODE_USER="${T3CODE_USER:-t3}"
T3CODE_PORT="${T3CODE_PORT:-3773}"
T3_BIN="/home/$T3CODE_USER/.local/bin/t3"
T3_UNIT="/home/$T3CODE_USER/.config/systemd/user/t3code.service"

_uenv() {
    # runuser, never sudo: the sudo shadow flattens argv into 'bash -c' and
    # mangles 'sudo -u <user> env ...' (see install.sh).
    runuser -u "$T3CODE_USER" -- env \
        HOME="/home/$T3CODE_USER" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$T3CODE_USER")" \
        PATH="/home/$T3CODE_USER/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        "$@"
}

[[ -x "$T3_BIN" ]] || die "t3code: $T3_BIN missing - run 'cloudify install t3code' first" 1
[[ -f "$T3_UNIT" ]] || die "t3code: unit $T3_UNIT missing - run 'cloudify install t3code' first" 1

_before=$(_uenv t3 --version 2>/dev/null | head -1)

# Lingering converges here too (a linger switched off elsewhere is repaired).
loginctl enable-linger "$T3CODE_USER" || die "t3code: loginctl enable-linger $T3CODE_USER failed" 1

# Vendor installer re-run: newest release on the channel (or the pinned version).
# Same rules as install: file, then `sh <file>`; never pipe into sh.
_installer=$(mktemp) || die "t3code: cannot create temp file" 1
curl -fsSL "https://t3.codes/install.sh" -o "$_installer" \
    || { rm -f "$_installer"; die "t3code: cannot download the installer" 1; }
if [[ -n "$T3CODE_VERSION" ]]; then
    _uenv T3CODE_VERSION="$T3CODE_VERSION" sh "$_installer"
    _rc=$?
else
    _uenv T3CODE_CHANNEL="$T3CODE_CHANNEL" sh "$_installer"
    _rc=$?
fi
rm -f "$_installer"
[[ $_rc -eq 0 ]] || die "t3code: installer failed during configure" 1

# Repair/re-register the service, then restart only on a real version move.
_uenv t3 service install || die "t3code: 't3 service install' failed during configure" 1
_after=$(_uenv t3 --version 2>/dev/null | head -1)
if [[ -n "$_before" && "$_before" != "$_after" ]]; then
    log_info "t3code: version moved ($_before -> $_after), restarting the service"
    _uenv t3 service restart || die "t3code: 't3 service restart' failed after update" 1
fi
_uenv systemctl --user is-active t3code.service >/dev/null 2>&1 \
    || die "t3code: service not active after configure" 1

# --- Wait for the server to answer ------------------------------------------------
_ok=""
for _ in $(seq 1 60); do
    _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${T3CODE_PORT}/" 2>/dev/null || true)
    [[ "$_code" == 200 || "$_code" == 401 ]] && { _ok=1; break; }
    sleep 2
done
[[ -n "$_ok" ]] || die "t3code: no answer on 127.0.0.1:${T3CODE_PORT} after configure" 1

msg ""
msg "${GREEN}t3code converged${RESET} ($_after)"
msg "Server: http://127.0.0.1:${T3CODE_PORT} - unit t3code.service active"
msg ""
