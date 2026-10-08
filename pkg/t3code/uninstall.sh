#!/usr/bin/env bash
# t3code - uninstall leg (lifecycle teardown; the runbook's explicit phase).
# Plain: T3's own `t3 service uninstall` (stop + remove the user unit), then
# remove the linger this recipe added. ~/.t3 (runtime + userdata: projects,
# threads, settings, the Connect identity) is DATA - upstream keeps it on
# uninstall and so do we.
# --clear-data (CLOUDIFY_CLEAR_DATA=true): additionally remove ~/.t3 and the
# dedicated user entirely (a decommission: account link, threads, runtime all die).
# Idempotent: every step tolerates an already-absent install.

T3CODE_USER="${T3CODE_USER:-t3}"
T3_HOME="/home/$T3CODE_USER/.t3"
T3_BIN="/home/$T3CODE_USER/.local/bin/t3"
T3_UNIT="/home/$T3CODE_USER/.config/systemd/user/t3code.service"

_uenv() {
    sudo -u "$T3CODE_USER" env \
        HOME="/home/$T3CODE_USER" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$T3CODE_USER")" \
        PATH="/home/$T3CODE_USER/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        "$@"
}

# --- Teardown the service (T3's own uninstaller) -----------------------------------
if [[ -x "$T3_BIN" ]]; then
    _uenv t3 service uninstall \
        || die "t3code: 't3 service uninstall' failed - check journalctl (user $T3CODE_USER)" 1
    log_info "t3code: background service removed"
else
    log_info "t3code: no t3 binary - service already gone"
    rm -f "$T3_UNIT" 2>/dev/null || true
fi

# Linger was added by this package; remove it with the package.
if loginctl disable-linger "$T3CODE_USER" 2>/dev/null; then
    log_info "t3code: linger disabled for $T3CODE_USER"
fi

# --- Optional data + user wipe -------------------------------------------------------
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    if id -u "$T3CODE_USER" >/dev/null 2>&1; then
        userdel -r "$T3CODE_USER" 2>/dev/null \
            || { rm -rf "${T3_HOME:?}" "/home/${T3CODE_USER:?}" 2>/dev/null || true; \
                 log_info "t3code: userdel failed, removed /home/$T3CODE_USER directly"; }
        log_info "t3code: user $T3CODE_USER and its home removed (runtime + userdata)"
    fi
elif [[ -d "$T3_HOME" ]]; then
    log_info "t3code: state kept at $T3_HOME (userdata; --clear-data to wipe)"
fi

# --- Postconditions (recipes run with errexit suspended - assert explicitly) ---------
if [[ -f "$T3_UNIT" ]]; then die "t3code: unit file still present after uninstall"; fi
if id -u "$T3CODE_USER" >/dev/null 2>&1 \
    && sudo -u "$T3CODE_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$T3CODE_USER")" \
        systemctl --user is-active t3code.service >/dev/null 2>&1; then
    die "t3code: service still active after uninstall"
fi
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]] && [[ -d "$T3_HOME" ]]; then
    die "t3code: $T3_HOME still present after --clear-data"
fi

msg ""
msg "${GREEN}t3code uninstalled${RESET}${CLOUDIFY_CLEAR_DATA:+ (data + user wiped)}"
msg "Provider CLIs and other users on the host were never touched."
msg ""
