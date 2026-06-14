#!/usr/bin/env bash
# pkg/hermes-openwebui/verify.sh — verification hook.
#
# Branch-aware: same-container (local) vs separate-containers (remote) deployment.
# No hardcoded endpoints — inputs come from env vars (yaml/credentials) or the
# config file the recipe wrote (~/.hermes/.env).
#
# Per the deep-verify authoring contract:
#   - hermes-openwebui OWNS the Hermes API connection check (constraint b):
#     it wires Open WebUI to the API, so it verifies that wiring.
#   - The base hermes package does NOT verify the gateway (it can't know how the
#     API is exposed). See ROADMAP: "hermes-owns-gateway".
pkg_verify() {
    local openwebui_port="${CLOUDIFY_OPENWEBUI_PORT:-3000}"

    # Open WebUI health — works in both modes (Docker on this host).
    curl -sf --max-time 5 "http://127.0.0.1:${openwebui_port}/health" >/dev/null || return 1

    # Hermes API health — depends on deployment mode (detected by which env
    # var is populated, NOT by hardcoded hostnames).
    if [[ -n "${CLOUDIFY_HERMES_API_URL:-}" ]]; then
        # Remote mode: separate containers, reach Hermes via MagicDNS URL.
        curl -sf --max-time 5 "${CLOUDIFY_HERMES_API_URL%/}/health" >/dev/null || return 1
    else
        # Local mode: same container. Read the API port back from the config
        # file the recipe wrote (not a recipe-local var — those don't survive).
        local hermes_env="$HOME/.hermes/.env"
        [[ -f "$hermes_env" ]] || return 1
        local api_port
        api_port=$(grep -E "^API_SERVER_PORT=" "$hermes_env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d "\"'")
        api_port="${api_port:-8642}"
        curl -sf --max-time 5 "http://127.0.0.1:${api_port}/health" >/dev/null || return 1
    fi
}
