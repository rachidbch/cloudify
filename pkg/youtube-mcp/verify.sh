#!/usr/bin/env bash
# pkg/youtube-mcp/verify.sh — verification hook.
# Sourced in a clean subshell. Port comes from env var with a default.
pkg_verify() {
    local port="${YOUTUBE_MCP_PORT:-8443}"
    systemctl is-active youtube-mcp >/dev/null 2>&1 || return 1
    # Port is listening
    ss -tlnp "sport = :${port}" 2>/dev/null | grep -q ":${port}" || return 1
}
