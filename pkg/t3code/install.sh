#!/usr/bin/env bash
# t3code - install phase (ADR-008 split): provision T3 Code (pingdotgg/t3code,
# the `t3` CLI + server) on the nightly train via the OFFICIAL installer, as a
# DEDICATED NON-ROOT USER (upstream: running T3 Code as root creates a separate
# installation and Connect identity), and register the background service
# through T3's own `t3 service install` (systemd user unit + linger).
#
# Verified on ubuntu/24.04 cloud container against v0.0.46-nightly (probe):
#   - the t3 binary needs libatomic.so.1 (dep libatomic1) - the installer's
#     self-test catches a missing one and refuses to install;
#   - `t3 service install` via `sudo -u` fails [user-manager-unavailable]
#     unless XDG_RUNTIME_DIR=/run/user/<uid> is set (the user manager IS
#     running once linger is on - sudo just doesn't point at its socket);
#   - `t3 browser setup` (headless Chrome sandbox) needs the apparmor package,
#     then succeeds on the container;
#   - the server listens on 127.0.0.1:3773 and logs to
#     ~/.t3/userdata/logs/boot-service.log.
#
# Config (~/.config/cloudify/pkgs/t3code.yaml or caller env):
#   T3CODE_CHANNEL (default nightly)   T3CODE_VERSION (default empty = newest on channel)
#   T3CODE_USER (default t3)           T3CODE_PORT (default 3773)
# No credentials ever pass through this recipe: pairing/auth happens later
# through `t3 connect --headless` (the runbook's human-gate) with the
# operator's own T3 account.

T3CODE_CHANNEL="${T3CODE_CHANNEL:-nightly}"
T3CODE_VERSION="${T3CODE_VERSION:-}"
T3CODE_USER="${T3CODE_USER:-t3}"
T3CODE_PORT="${T3CODE_PORT:-3773}"
T3_HOME="/home/$T3CODE_USER/.t3"
T3_BIN="/home/$T3CODE_USER/.local/bin/t3"
T3_UNIT="/home/$T3CODE_USER/.config/systemd/user/t3code.service"
T3_INSTALLER="https://t3.codes/install.sh"

_uenv() { # run a command as the T3 user with the session env systemd needs
    # runuser, never sudo: the cloudify sudo shadow flattens argv into one
    # 'bash -c' string, which mangles 'sudo -u <user> env ...' into bash
    # option-parsing garbage. runuser is plain util-linux, root-only.
    runuser -u "$T3CODE_USER" -- env \
        HOME="/home/$T3CODE_USER" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$T3CODE_USER")" \
        PATH="/home/$T3CODE_USER/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        "$@"
}

# --- Dependencies --------------------------------------------------------------
# libatomic1: the t3 binary links against libatomic.so.1 (self-test at install).
# apparmor: `t3 browser setup` loads a Chrome-sandbox allow profile through it.
pkg_apt_install curl tar ca-certificates libatomic1 apparmor

# --- Dedicated user (create-if-absent) ------------------------------------------
if ! id -u "$T3CODE_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$T3CODE_USER" || die "t3code: cannot create user $T3CODE_USER" 1
    log_info "t3code: created user $T3CODE_USER (T3 Code must not run as root)"
fi

# --- Install guard ---------------------------------------------------------------
if [[ -x "$T3_BIN" ]] && [[ -f "$T3_UNIT" ]] \
    && _uenv systemctl --user is-active t3code.service >/dev/null 2>&1 \
    && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "t3code already installed and running. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Clear data if requested ------------------------------------------------------
# ~/.t3 holds the runtime AND all userdata (projects, threads, settings) - the
# account link and every conversation die with it. Next install starts fresh.
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]] && [[ -d "$T3_HOME" ]]; then
    log_info "t3code: clearing $T3_HOME (runtime + userdata)..."
    _uenv t3 service uninstall >/dev/null 2>&1 || true
    rm -rf "$T3_HOME" "/home/$T3CODE_USER/.local/bin/t3" "$T3_UNIT" \
        || die "t3code: cannot remove $T3_HOME" 1
fi

# --- Install (official installer, channel/version env) -----------------------------
# The installer resolves the newest release tag on the channel through the
# GitHub API, verifies SHA256SUMS, unpacks to $T3_HOME/runtime/versions/<v> and
# symlinks ~/.local/bin/t3. Download to a file, run `sh <file>` - never pipe.
if [[ ! -x "$T3_BIN" ]]; then
    log_info "t3code: running official installer (channel $T3CODE_CHANNEL${T3CODE_VERSION:+, version $T3CODE_VERSION})..."
    _installer=$(mktemp) || die "t3code: cannot create temp file" 1
    chmod 644 "$_installer" # mktemp is 0600 root; t3 must read it
    curl -fsSL "$T3_INSTALLER" -o "$_installer" \
        || { rm -f "$_installer"; die "t3code: cannot download the installer from $T3_INSTALLER" 1; }
    if [[ -n "$T3CODE_VERSION" ]]; then
        _uenv T3CODE_VERSION="$T3CODE_VERSION" sh "$_installer"
        _rc=$?
    else
        _uenv T3CODE_CHANNEL="$T3CODE_CHANNEL" sh "$_installer"
        _rc=$?
    fi
    rm -f "$_installer"
    [[ $_rc -eq 0 ]] || die "t3code: installer failed (see its output above)" 1
else
    log_info "t3code: $T3_BIN already present - keeping it (upgrade is configure's job)"
fi

# Postcondition: the binary answers as the user.
_t3_version=$(_uenv t3 --version) || die "t3code: 't3 --version' failed after install" 1
log_info "t3code: installed $(_uenv t3 --version 2>/dev/null | head -1)"

# --- Lingering: service survives logout and starts at boot --------------------------
loginctl enable-linger "$T3CODE_USER" || die "t3code: loginctl enable-linger $T3CODE_USER failed" 1

# --- Background service (T3's own registration) --------------------------------------
# Rewrites the user unit pinned to the freshly linked version and starts it.
# XDG_RUNTIME_DIR is mandatory here (see header): the user manager is running
# (linger), but sudo does not point at its socket by itself.
_uenv t3 service install || die "t3code: 't3 service install' failed" 1

# Converge the unit onto the running binary: the unit pins the exact version
# path; if the symlink moved to a newer release, restart picks it up.
_uenv t3 service restart >/dev/null 2>&1 || true
_uenv systemctl --user is-active t3code.service >/dev/null 2>&1 \
    || die "t3code: service not active after 't3 service install'" 1

# --- Headless-Chrome sandbox (browser tabs / HTML previews) ---------------------------
# Ubuntu >= 23.10 blocks Chrome's unprivileged sandbox; the container also lacks
# libraries. One-time, idempotent, safe to re-run. Failure is non-fatal: browser
# tabs then need T3CODE_SERVER_BROWSER_SANDBOX=0 (documented escape hatch).
# As root but with the T3 user's HOME: the profile targets its AppArmor + apt
# setup at that home layout (verified form from the probe).
if HOME="/home/$T3CODE_USER" PATH="/home/$T3CODE_USER/.local/bin:/usr/bin:/bin" \
    t3 browser setup >/dev/null 2>&1; then
    log_info "t3code: browser sandbox OK (headless Chrome may install on first tab)"
else
    log_info "t3code: browser setup skipped (browser tabs need T3CODE_SERVER_BROWSER_SANDBOX=0)"
fi

# --- Wait for the server to answer ----------------------------------------------------
_ok=""
for _ in $(seq 1 60); do
    _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${T3CODE_PORT}/" 2>/dev/null || true)
    [[ "$_code" == 200 || "$_code" == 401 ]] && { _ok=1; break; }
    sleep 2
done
if [[ -z "$_ok" ]]; then
    tail -20 "/home/$T3CODE_USER/.t3/userdata/logs/boot-service.log" 2>/dev/null || true
    die "t3code: no answer on 127.0.0.1:${T3CODE_PORT} after install" 1
fi

# --- Post-install ----------------------------------------------------------------------
msg ""
msg "${GREEN}t3code running ($(_uenv t3 --version 2>/dev/null | head -1), systemd user unit 't3code.service')${RESET}"
msg "Server:    http://127.0.0.1:${T3CODE_PORT} (loopback; clients pair over T3 Connect or a pairing URL)"
msg "State:     $T3_HOME (runtime + userdata)"
msg "Logs:      /home/$T3CODE_USER/.t3/userdata/logs/boot-service.log"
msg "Pairing:   run the runbook's connect steps ('t3 connect --headless' device flow),"
msg "           or on the host: t3 pair (SSH tunnel) / t3 pair --tailscale (tailnet HTTPS)."
msg "Providers: auth at least one (claude/codex/...) from the web/desktop app Settings."
msg ""
