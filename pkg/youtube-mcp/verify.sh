#!/usr/bin/env bash
# pkg/youtube-mcp/verify.sh — deep verification hook.
# Sourced in a clean subshell: inputs from env/config files only.
# The endpoint token is server-owned (state file), never a cloudify var.
pkg_verify() {
    local port="${YOUTUBE_MCP_PORT:-8443}"
    local token_file="/var/lib/youtube-mcp/token"
    local timeout="${PKG_VERIFY_TIMEOUT:-30}"
    local waited=0 token body

    systemctl is-active youtube-mcp >/dev/null 2>&1 || return 1
    ss -tlnp "sport = :${port}" 2>/dev/null | grep -q ":${port}" || return 1

    # Token must exist (server generates it at first start).
    while [[ ! -s "$token_file" ]]; do
        (( waited += 2 )); (( waited >= timeout )) && return 1
        sleep 2
    done
    token=$(<"$token_file")

    # Bearer must be accepted: initialize returns serverInfo in the SSE body.
    while :; do
        body=$(curl -s --max-time 10 -X POST "http://127.0.0.1:${port}/mcp" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json, text/event-stream" \
            -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"cloudify-verify","version":"0"}}}' 2>/dev/null)
        [[ "$body" == *"youtube-mcp"* ]] && return 0
        (( waited += 3 )); (( waited >= timeout )) && return 1
        sleep 3
    done
}
