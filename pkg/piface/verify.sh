#!/usr/bin/env bash
# pkg/piface/verify.sh — verification hook.
# Sourced in a clean subshell. Port from env var (yaml) with a default.
pkg_verify() {
    local port="${PIFACE_PORT:-7832}"
    systemctl --user is-active piface >/dev/null 2>&1 || return 1
    curl -sf --max-time 5 "http://127.0.0.1:${port}" >/dev/null || return 1
}
