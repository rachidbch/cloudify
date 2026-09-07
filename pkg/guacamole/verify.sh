#!/usr/bin/env bash
# guacamole verify.sh - local endpoint health (SOP "Verification").
# Sourced FRESH in a clean subshell by _cloudify_run_verify on every attempt
# (retried until PKG_VERIFY_TIMEOUT). Reads state only from the on-disk .env
# (last configure state) + defaults - never recipe-local vars, never hardcoded
# endpoints, so it also works on remote verify-only runs that forward no
# package vars. Raise PKG_VERIFY_TIMEOUT (e.g. 300) for first-boot image pulls.
pkg_verify() {
    local dir="${CLOUDIFY_GUACAMOLE_DIR:-$HOME/guacamole}"
    local compose_file="$dir/docker-compose.yml"
    [[ -f "$compose_file" ]] || return 1
    local env_file="$dir/.env"
    [[ -f "$env_file" ]] || return 1
    # shellcheck source=/dev/null
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a

    # All three services running.
    local svc
    for svc in postgres guacd guacamole; do
        sudo docker compose -f "$compose_file" ps -q "$svc" 2>/dev/null | grep -q . || return 1
    done

    # Webapp answers HTTP on the configured bind/port.
    local base_url="http://${GUACAMOLE_BIND:-127.0.0.1}:${GUACAMOLE_PORT:-8080}"
    curl -fsS -o /dev/null "$base_url/" || return 1

    # Administrator can obtain an API token.
    local login token ds id
    login="$(curl -fsS -X POST "$base_url/api/tokens" \
        --data-urlencode "username=${CLOUDIFY_GUACAMOLE_ADMIN_USER:-rbc}" \
        --data-urlencode "password=${CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD:-}" 2>/dev/null)" || return 1
    token="$(printf '%s' "$login" | jq -r '.authToken // empty' 2>/dev/null)" || return 1
    [[ -n "$token" ]] || return 1
    ds="$(printf '%s' "$login" | jq -r '.dataSource // "postgresql"')"

    # Connection record exists with the expected RDP target.
    id="$(curl -fsS "$base_url/api/session/data/${ds}/connections?token=${token}" 2>/dev/null \
        | jq -r --arg n "${CLOUDIFY_GUACAMOLE_CONNECTION_NAME:-GUI}" \
            'to_entries[] | select(.value.name == $n) | .key' 2>/dev/null | head -n1)" || return 1
    [[ -n "$id" ]] || return 1

    curl -fsS "$base_url/api/session/data/${ds}/connections/${id}/parameters?token=${token}" 2>/dev/null \
        | jq -e --arg h "${CLOUDIFY_GUACAMOLE_RDP_HOST:-}" --arg p "${CLOUDIFY_GUACAMOLE_RDP_PORT:-3389}" \
            '(.hostname == $h) and (.port == $p)' >/dev/null || return 1
}
