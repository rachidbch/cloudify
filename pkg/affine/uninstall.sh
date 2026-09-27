#!/usr/bin/env bash
# affine - uninstall leg (lifecycle teardown; the runbook's explicit phase).
# Plain: stop + disable the systemd user unit, remove the unit file. The
# source clone and data/ stay - data belongs to the external backup process
# (README contract), and the clone is rebuilt by install.
# --clear-data (CLOUDIFY_CLEAR_DATA=true): additionally remove $AFFINE_DIR
# entirely (source + node_modules + data/ incl. state.db and the master
# token - a wiped token is a dead token).
# Idempotent: every step tolerates an already-absent install.
# Dependencies (git, mise, node) are never removed (shared).

AFFINE_DIR="${AFFINE_DIR:-$HOME/PROJECTS/affine}"
AFFINE_SERVICE="$HOME/.config/systemd/user/affine-mcp.service"

# --- Teardown the service -----------------------------------------------------
systemctl --user stop affine-mcp 2>/dev/null || log_info "affine: unit not loaded - nothing to stop"
systemctl --user disable affine-mcp 2>/dev/null || true

if [[ -f "$AFFINE_SERVICE" ]]; then
    rm -f "$AFFINE_SERVICE" || die "affine: cannot remove $AFFINE_SERVICE"
    systemctl --user daemon-reload || die "affine: daemon-reload failed"
    systemctl --user reset-failed 2>/dev/null || true
    log_info "affine: unit removed"
else
    log_info "affine: no unit file present"
fi

# --- Optional data wipe --------------------------------------------------------
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    if [[ -d "$AFFINE_DIR" ]]; then
        rm -rf "$AFFINE_DIR" || die "affine: cannot remove $AFFINE_DIR"
        log_info "affine: removed $AFFINE_DIR (source + data + master token)"
    fi
elif [[ -d "$AFFINE_DIR/data" ]]; then
    log_info "affine: data kept at $AFFINE_DIR/data (external backup owns it; --clear-data to wipe)"
fi

# --- Postconditions (recipes run with errexit suspended - assert explicitly) ---
systemctl --user is-active affine-mcp >/dev/null 2>&1 && die "affine: unit still active after uninstall"
[[ -f "$AFFINE_SERVICE" ]] && die "affine: unit file still present after uninstall"
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    [[ -d "$AFFINE_DIR" ]] && die "affine: $AFFINE_DIR still present after --clear-data"
fi

msg ""
msg "${GREEN}affine uninstalled${RESET}${CLOUDIFY_CLEAR_DATA:+ (data wiped)}"
msg "Dependencies (git, mise, node) left in place - cloudify never removes shared deps."
msg ""
