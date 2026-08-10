#!/usr/bin/env bash
# pkg/affine/verify.sh — verification hook.
# Sourced in a clean subshell. Port from env var (yaml) with a default.
pkg_verify() {
    local port="${AFFINE_PORT:-8787}"
    systemctl --user is-active affine-mcp >/dev/null 2>&1 || return 1
    # Unauthenticated POST /mcp must answer 401 (server up + auth enforced).
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -X POST -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
        "http://127.0.0.1:${port}/mcp")
    [[ "$code" == "401" ]] || return 1
}
