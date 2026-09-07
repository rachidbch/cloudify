#!/usr/bin/env bash
# xfce verify.sh - local endpoint health (SOP "Verification"). Sourced FRESH
# in a clean subshell by _cloudify_run_verify on every attempt (retried until
# PKG_VERIFY_TIMEOUT). Reads everything from the on-disk state file
# (/etc/cloudify/xfce-user.env, written by install) - never recipe-local vars,
# never hardcoded endpoints, so it also works on remote verify-only runs that
# forward no package vars. Cannot prove remote RDP render; that is the E2E gate.
pkg_verify() {
    local state_file=/etc/cloudify/xfce-user.env
    [[ -f "$state_file" ]] || return 1
    # shellcheck source=/dev/null
    set -a
    # shellcheck disable=SC1090
    source "$state_file"
    set +a

    [[ -n "${XFCE_USER:-}" ]] || return 1
    local home
    home="$(getent passwd "${XFCE_USER}" | cut -d: -f6)" || return 1
    [[ -n "$home" ]] || return 1

    # Session file carries the configured session command.
    [[ -f "$home/.xsession" ]] || return 1
    grep -qF "${XFCE_SESSION:-startxfce4}" "$home/.xsession" || return 1

    # XRDP active + listening on the configured port.
    systemctl is-active --quiet xrdp || return 1
    ss -ltn 2>/dev/null | grep -qE ":${XFCE_RDP_PORT:-3389}\b" || return 1

    # key.pem resolvable and xrdp in ssl-cert (oracle fact).
    [[ -e /etc/xrdp/key.pem ]] || return 1
    getent group ssl-cert | grep -qw xrdp || return 1

    # Chrome + default-browser registration when chrome is enabled.
    if [[ "${XFCE_CHROME:-true}" == "true" ]]; then
        command -v google-chrome >/dev/null 2>&1 || return 1
        [[ -f "$home/.config/xfce4/helpers.rc" ]] || return 1
        grep -qF "WebBrowser=google-chrome" "$home/.config/xfce4/helpers.rc" || return 1
    fi
}
