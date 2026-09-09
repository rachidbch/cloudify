#!/usr/bin/env bash
# lib/secrets.sh - Thin loader for secret-backend modules
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_SECRETS_LOADED:-}" ]] && return 0
_CLOUDIFY_SECRETS_LOADED=1

##  A var value may be a secret reference `@<backend>:<locator>` instead of a
##  literal. Backends live in lib/secrets/*.sh, mirroring lib/shadow.sh ->
##  lib/shadows/*.sh: each file defines cloudify_secret_backend_<name>.

_cloudify_secrets_dir() {
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secrets"
}

_cloudify_secrets_dir_exists() {
    [[ -d "$(_cloudify_secrets_dir)" ]]
}

if _cloudify_secrets_dir_exists; then
    for _secret_file in "$(_cloudify_secrets_dir)"/*.sh; do
        # shellcheck source=/dev/null
        [[ -f "$_secret_file" ]] && source "$_secret_file"
    done
    unset _secret_file
fi

# cloudify_secret_resolve <var-name> <backend> <locator>
# Prints the resolved secret on success; returns non-zero on unknown backend or
# backend failure. Never prints an empty value for a failed backend.
cloudify_secret_resolve() {
    local name="$1" backend="$2" locator="$3"
    local fn="cloudify_secret_backend_${backend}"
    if ! declare -F "$fn" >/dev/null 2>&1; then
        log_error "Var $name: unknown secret backend '$backend'."
        return 1
    fi
    local out
    if ! out=$("$fn" "$locator"); then
        log_error "Var $name: secret backend '$backend' failed to resolve its locator."
        return 1
    fi
    printf '%s' "$out"
}
