#!/usr/bin/env bash
# zitadel verify.sh - local stack health (SOP "Verification").
# Sourced FRESH in a clean subshell by _cloudify_run_verify on every attempt
# (retried until PKG_VERIFY_TIMEOUT). Reads state only from the on-disk .env
# (last configure state) + defaults - never recipe-local vars - so it also
# works on remote verify-only runs that forward no package vars.
# Raise PKG_VERIFY_TIMEOUT (e.g. 600) for first-boot image pulls + migrations.
pkg_verify() {
    local dir="${CLOUDIFY_ZITADEL_DIR:-$HOME/zitadel}"
    local compose_file="$dir/docker-compose.yml"
    [[ -f "$compose_file" ]] || return 1
    local env_file="$dir/.env"
    [[ -f "$env_file" ]] || return 1
    # shellcheck source=/dev/null
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a

    local domain="${CLOUDIFY_ZITADEL_DOMAIN:-}"
    local port="${CLOUDIFY_ZITADEL_PORT:-8080}"
    [[ -n "$domain" ]] || return 1

    # All four services running.
    local svc
    for svc in proxy zitadel-api zitadel-login postgres; do
        sudo docker compose -f "$compose_file" ps -q "$svc" 2>/dev/null | grep -q . || return 1
    done

    # Local probes go through traefik, so they must carry the routed Host.
    # API readiness (DB-inclusive).
    curl -fsS -o /dev/null -H "Host: ${domain}" "http://127.0.0.1:${port}/debug/ready" || return 1

    # Login v2 UI health.
    curl -fsS -o /dev/null -H "Host: ${domain}" "http://127.0.0.1:${port}/ui/v2/login/healthy" || return 1

    # Bootstrap PAT authenticates against the Mgmt API (deep check:
    # proves instance init ran and the IAM_OWNER machine exists).
    local pat_file="$dir/bootstrap.pat"
    [[ -s "$pat_file" ]] || return 1
    local pat
    pat="$(cat "$pat_file")" || return 1
    [[ -n "$pat" ]] || return 1
    curl -fsS -o /dev/null -H "Host: ${domain}" -H "Authorization: Bearer ${pat}" \
        "http://127.0.0.1:${port}/management/v1/iam" || return 1
}
