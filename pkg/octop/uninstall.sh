#!/usr/bin/env bash
# octop - uninstall leg (lifecycle teardown; the runbook's explicit phase).
# Plain: stop + disable the systemd user unit, remove the unit file and the
# Octop-written drop-in. $OCTOP_HOME (venv + octop.db + workspaces + env) is
# DATA - it stays: the control plane holds users, agents and memories.
# --clear-data (CLOUDIFY_CLEAR_DATA=true): additionally remove $OCTOP_HOME
# entirely (a wiped admin is a dead admin; next install re-inits).
# Idempotent: every step tolerates an already-absent install.

OCTOP_HOME="${OCTOP_HOME:-$HOME/.octop}"
OCTOP_BIN="$OCTOP_HOME/bin/octop"
OCTOP_UNIT="$HOME/.config/systemd/user/octop.service"
OCTOP_DROPIN="$HOME/.config/systemd/user/octop.service.d"

# --- Teardown the service -------------------------------------------------------
if [[ -x "$OCTOP_BIN" ]]; then
    OCTOP_SERVICE_SCOPE=user "$OCTOP_BIN" service stop 2>/dev/null \
        || systemctl --user stop octop 2>/dev/null \
        || log_info "octop: unit not loaded - nothing to stop"
else
    systemctl --user stop octop 2>/dev/null || log_info "octop: unit not loaded - nothing to stop"
fi
systemctl --user disable octop 2>/dev/null || true

if [[ -f "$OCTOP_UNIT" || -d "$OCTOP_DROPIN" ]]; then
    rm -rf "$OCTOP_UNIT" "$OCTOP_DROPIN" || die "octop: cannot remove the unit files"
    systemctl --user daemon-reload || die "octop: daemon-reload failed"
    systemctl --user reset-failed 2>/dev/null || true
    log_info "octop: unit + drop-in removed"
else
    log_info "octop: no unit files present"
fi

# --- Optional data wipe -----------------------------------------------------------
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    if [[ -d "$OCTOP_HOME" ]]; then
        rm -rf "$OCTOP_HOME" || die "octop: cannot remove $OCTOP_HOME"
        log_info "octop: removed $OCTOP_HOME (venv + database + workspaces)"
    fi
elif [[ -d "$OCTOP_HOME" ]]; then
    log_info "octop: state kept at $OCTOP_HOME (venv + data; --clear-data to wipe)"
fi

# --- Postconditions (recipes run with errexit suspended - assert explicitly) ------
systemctl --user is-active octop >/dev/null 2>&1 && die "octop: unit still active after uninstall"
[[ -f "$OCTOP_UNIT" ]] && die "octop: unit file still present after uninstall"
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    [[ -d "$OCTOP_HOME" ]] && die "octop: $OCTOP_HOME still present after --clear-data"
fi

msg ""
msg "${GREEN}octop uninstalled${RESET}${CLOUDIFY_CLEAR_DATA:+ (data wiped)}"
msg "Dependencies (uv, python) live inside \$OCTOP_HOME - nothing shared was touched."
msg ""
