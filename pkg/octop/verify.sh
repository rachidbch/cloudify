#!/usr/bin/env bash
# pkg/octop - verification hook (sourced in a clean subshell).
# Inputs from env vars (exported dispatch env + on-disk env file), never
# hardcoded endpoints. Public GET /health answers {"status":"ok",...}.

pkg_verify() {
    local port="${OCTOP_PORT:-8088}"
    # Unmasked: a swallowed bus/systemd error makes the timeout opaque - the
    # runner captures stderr as the failure reason.
    systemctl --user is-active octop || return 1
    local body
    body=$(curl -s --max-time 5 "http://127.0.0.1:${port}/health") || return 1
    [[ "$body" == *'"status": "ok"'* || "$body" == *'"status":"ok"'* ]] || return 1
}
