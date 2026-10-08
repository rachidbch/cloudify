#!/usr/bin/env bash
# pkg/t3code - verification hook (sourced in a clean subshell).
# Inputs from env vars only (declared names + exported dispatch env), never
# hardcoded endpoints. Root queries the USER unit as the user through
# runuser + XDG_RUNTIME_DIR - NOT `systemctl --machine=<user>@.host`: machined
# registration goes stale across user-manager restarts (verified: "Unit could
# not be found" while the unit was active) and once returned a stale active.
# A 401 from the server means "up, and requiring auth" - both 200 and 401
# prove the listener. Loop stays under the framework's PKG_VERIFY_TIMEOUT
# (default 30s): the outer verify retry handles a slow post-update boot.
# Pairing/auth state is deliberately NOT verified here: it is the operator's
# account, driven by the runbook's connect steps.

pkg_verify() {
    local user="${T3CODE_USER:-t3}"
    local port="${T3CODE_PORT:-3773}"
    local code="" left=8
    while (( left > 0 )); do
        if runuser -u "$user" -- env \
            XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" \
            HOME="/home/$user" \
            systemctl --user is-active t3code.service >/dev/null 2>&1; then
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/" 2>/dev/null) || true
            [[ "$code" == 200 || "$code" == 401 ]] && return 0
        fi
        left=$(( left - 1 ))
        sleep 2
    done
    return 1
}
