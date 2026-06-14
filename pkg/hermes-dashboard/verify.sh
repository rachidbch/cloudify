#!/usr/bin/env bash
# pkg/hermes-dashboard/verify.sh — verification hook.
# Sourced in a clean subshell. Port comes from env var (yaml) with a default.
pkg_verify() {
    local port="${HERMES_DASHBOARD_PORT:-9119}"
    systemctl --user is-active hermes-dashboard >/dev/null 2>&1 || return 1
    curl -sf --max-time 5 "http://127.0.0.1:${port}" >/dev/null || return 1
}
