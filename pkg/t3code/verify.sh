#!/usr/bin/env bash
# pkg/t3code - verification hook (sourced in a clean subshell).
# Inputs from env vars only (declared names + exported dispatch env), never
# hardcoded endpoints. Root checks the USER unit through machined
# (--machine=<user>@.host) - the dispatch session has no user-session env.
# A 401 from the server means "up, and requiring auth" - both 200 and 401
# prove the listener. Pairing/auth state is deliberately NOT verified here:
# it is the operator's account, driven by the runbook's connect steps.

pkg_verify() {
    local user="${T3CODE_USER:-t3}"
    local port="${T3CODE_PORT:-3773}"
    # Unmasked: a swallowed bus/systemd error makes the timeout opaque - the
    # runner captures stderr as the failure reason.
    systemctl --machine="${user}@.host" is-active t3code.service || return 1
    local code="" left=15
    while (( left > 0 )); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/" 2>/dev/null) || true
        [[ "$code" == 200 || "$code" == 401 ]] && return 0
        left=$(( left - 1 ))
        sleep 2
    done
    return 1
}
