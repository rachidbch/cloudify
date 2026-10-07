#!/usr/bin/env bash
# pkg/octop - verification hook (sourced in a clean subshell).
# Inputs from env vars (exported dispatch env + on-disk env file), never
# hardcoded endpoints. The real health endpoint is GET /api/health (JSON
# {"ok":true,...}). NOTE: the upstream README documents /health, but that
# path is swallowed by the dashboard SPA catch-all (200 HTML) - use /api/health.

pkg_verify() {
    local port="${OCTOP_PORT:-8088}"
    # Unmasked: a swallowed bus/systemd error makes the timeout opaque - the
    # runner captures stderr as the failure reason.
    systemctl --user is-active octop || return 1
    local body
    body=$(curl -s --max-time 5 "http://127.0.0.1:${port}/api/health") || return 1
    [[ "$body" == *'"ok":true'* ]] || return 1
}
