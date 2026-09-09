#!/usr/bin/env bash
# lib/vars.sh — five-source var helpers (ADR-007 + ADR-011)
#
# One read/write helper per var source. The collector
# (_cloudify_pkg_remote_vars, lib/remote.sh) is a thin precedence walker over
# these helpers. Target precedence (weakest -> strongest):
#   recipe default < global < package < deployment < caller env
#
# Readers export resolved values into the CURRENT shell (their exports are the
# value channel) and must be invoked with a redirect, never `$(...)` (I1).
# A reader called with a claim ledger set (_CLOUDIFY_VARS_LEDGER) is
# non-clobbering: the first source to claim a name wins, so the walker order
# alone decides precedence.
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_VARS_LOADED:-}" ]] && return 0
_CLOUDIFY_VARS_LOADED=1

# Secret backends (lib/secrets/*.sh) are needed by the value resolver below.
if [[ -z "${_CLOUDIFY_SECRETS_LOADED:-}" ]]; then
    # shellcheck source=/dev/null
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secrets.sh"
fi

# Framework-owned names a file store must never set (L5): a rogue
# `DEBUG: true` or `CLOUDIFY_REMOTE_USER: evil` would retarget execution.
_CLOUDIFY_VARS_RESERVED=(
    CLOUDIFY_REMOTE_USER
    CLOUDIFY_REMOTE_PWD
    DEBUG
    CLOUDIFY_BOOTSTRAP_URL
    CLOUDIFY_UPDATE_DELAY
)

_cloudify_vars_reserved() {
    local name="$1" r
    for r in "${_CLOUDIFY_VARS_RESERVED[@]}"; do
        [[ "$name" == "$r" ]] && return 0
    done
    return 1
}

# Claim a name in the walker ledger. Returns 1 when a stronger source already
# claimed it. With no ledger set, always returns 0 (legacy direct-call mode).
_cloudify_vars_claim() {
    local name="$1"
    [[ -n "${_CLOUDIFY_VARS_LEDGER:-}" ]] || return 0
    if grep -qx "$name" "$_CLOUDIFY_VARS_LEDGER" 2>/dev/null; then
        return 1
    fi
    echo "$name" >> "$_CLOUDIFY_VARS_LEDGER"
    return 0
}

_cloudify_vars_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Resolve a raw value to its literal form (R4).
#   plain      -> identity
#   @@foo      -> @foo (escape a literal leading @)
#   @b:locator -> cloudify_secret_backend_<b> locator
# Prints the resolved value; returns non-zero on malformed reference, unknown
# backend, or backend failure. Callers must die on non-zero (never forward empty).
_cloudify_resolve_var_value() {
    local name="$1" raw="$2" ref backend locator
    if [[ "$raw" == @@* ]]; then
        printf '%s' "${raw#@}"
        return 0
    fi
    if [[ "$raw" != @* ]]; then
        printf '%s' "$raw"
        return 0
    fi
    ref="${raw#@}"
    if [[ "$ref" != *:* || "$ref" == :* || "$ref" == *: ]]; then
        log_error "Var $name: malformed secret reference (expected @<backend>:<locator> or @@literal)."
        return 1
    fi
    backend="${ref%%:*}"
    locator="${ref#*:}"
    cloudify_secret_resolve "$name" "$backend" "$locator"
}

# Export one value from a file store, honouring the ledger and the reserved guard.
# _cloudify_vars_emit <name> <raw> [no-clobber] [print]
_cloudify_vars_emit() {
    local name="$1" raw="$2" mode="${3:-}" print="${4:-}"
    if _cloudify_vars_reserved "$name"; then
        log_warn "Var $name is framework-owned — ignored from file store."
        return 0
    fi
    _cloudify_vars_claim "$name" || return 0
    [[ -n "$print" ]] && echo "$name"
    # Non-clobbering only matters in walker mode (ledger set): the caller env is
    # the strongest source and file reads must not overwrite it.
    if [[ -n "${_CLOUDIFY_VARS_LEDGER:-}" && "$mode" == "no-clobber" && -n "${!name:-}" ]]; then
        return 0
    fi
    local value
    if ! value=$(_cloudify_resolve_var_value "$name" "$raw"); then
        die "Var $name: cannot resolve value — refusing to forward an empty value."
    fi
    export "$name"="$value"
}

# Parse a flat `KEY: value` file and export each value.
# _cloudify_load_yaml_vars <file> [no-clobber] [print]
# - no ledger: unconditional export (verify path, package-api.sh).
# - ledger set + no-clobber: first source to claim a name wins (walker).
function _cloudify_load_yaml_vars() {
    local file="$1"
    local mode="${2:-}"
    local print="${3:-}"
    [[ -f "$file" ]] || return 0

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        local key="${line%%:*}"
        local value="${line#*:}"
        key="${key## }"; key="${key%% }"
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue

        value="${value## }"; value="${value%% }"
        value="${value#\"}"; value="${value%\"}"
        value="${value#\'}"; value="${value%\'}"

        _cloudify_vars_emit "$key" "$value" "$mode" "$print"
    done < "$file"
}

# --- path helpers ---

cloudify_vars_config_dir() {
    echo "${CLOUDIFY_CREDENTIALS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/cloudify}"
}

cloudify_vars_global_file() {
    echo "$(cloudify_vars_config_dir)/remote-vars.yaml"
}

cloudify_vars_pkg_file() {
    echo "$(cloudify_vars_config_dir)/pkgs/$1.yaml"
}

# --- file writes (0700 dir / 0600 file, I10) ---

_cloudify_vars_chmod() {
    local file="$1"
    chmod 700 "$(dirname "$file")" 2>/dev/null || true
    chmod 600 "$file" 2>/dev/null || true
}

# _cloudify_vars_file_set <file> <key> <value> — replace or append one key.
_cloudify_vars_file_set() {
    local file="$1" key="$2" value="$3"
    [[ -n "$key" ]] || die "Usage: cloudify vars set <key> <value>"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid var name: $key"
    mkdir -p "$(dirname "$file")"
    local tmp
    tmp=$(mktemp)
    grep -v "^${key}:" "$file" > "$tmp" 2>/dev/null || true
    printf '%s: %s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$file"
    _cloudify_vars_chmod "$file"
}

# --- global source ---

cloudify_vars_global_read() {
    local file="${1:-$(cloudify_vars_global_file)}"
    local print=""
    [[ -z "${_CLOUDIFY_VARS_LEDGER:-}" ]] && print=1
    _cloudify_load_yaml_vars "$file" no-clobber "$print"
}

cloudify_vars_global_write() {
    _cloudify_vars_file_set "$(cloudify_vars_global_file)" "$1" "$2"
}

# --- package source ---

# cloudify_vars_pkg_read <pkg> [yaml-file]
# Declared names come from pkg/<pkg>/.remote-vars (values from caller env);
# values come from the per-package yaml. Declared names are recorded for the
# walker's deferred warn (L12) via _CLOUDIFY_VARS_DECLARED.
cloudify_vars_pkg_read() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 0
    local print=""
    [[ -z "${_CLOUDIFY_VARS_LEDGER:-}" ]] && print=1

    local decl="$CLOUDIFY_DIR/pkg/${pkg}/.remote-vars"
    if [[ -f "$decl" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue
            local name="${line## }"; name="${name%% }"
            [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
            if [[ -n "${_CLOUDIFY_VARS_DECLARED:-}" ]]; then
                printf '%s\t%s\n' "$name" "$pkg" >> "$_CLOUDIFY_VARS_DECLARED"
            fi
            if [[ -n "${!name:-}" ]]; then
                _cloudify_vars_claim "$name" || continue
                [[ -n "$print" ]] && echo "$name"
                export "$name"="${!name}"
            fi
        done < "$decl"
    fi

    _cloudify_load_yaml_vars "${2:-$(cloudify_vars_pkg_file "$pkg")}" no-clobber "$print"
}

cloudify_vars_pkg_write() {
    local pkg="$1"
    [[ -n "$pkg" ]] || die "Usage: cloudify vars set <key> <value> --pkg <name>"
    _cloudify_vars_file_set "$(cloudify_vars_pkg_file "$pkg")" "$2" "$3"
}

# --- deployment source ---

cloudify_vars_deployment_read() {
    local id="${1:-${CLOUDIFY_DEPLOYMENT:-}}"
    [[ -n "$id" ]] || return 0
    local config
    config=$(_cloudify_deployment_config "$id")
    [[ -f "$config" ]] || return 0
    local print=""
    [[ -z "${_CLOUDIFY_VARS_LEDGER:-}" ]] && print=1

    local line key raw
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" == *:* ]] || continue
        key="${line%%:*}"; raw="${line#*:}"
        key="${key## }"; key="${key%% }"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        raw=$(_cloudify_vars_trim "$raw")
        _cloudify_vars_emit "$key" "$raw" no-clobber "$print"
    done < "$config"
}

cloudify_vars_deployment_write() {
    local key="$1" value="$2"
    local id="${CLOUDIFY_DEPLOYMENT:-}"
    [[ -n "$key" ]] || die "Usage: cloudify vars set <key> <value>"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set. Set it or create a deployment first."
    _cloudify_deployment_ensure "$id"
    _cloudify_vars_file_set "$(_cloudify_deployment_config "$id")" "$key" "$value"
}

cloudify_vars_deployment_delete() {
    local key="$1"
    [[ -n "$key" ]] || die "Usage: cloudify vars delete <key>"
    local id="${CLOUDIFY_DEPLOYMENT:-}"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set."
    local config
    config=$(_cloudify_deployment_config "$id")
    [[ -f "$config" ]] || { log_info "No config for deployment '$id'."; return 0; }
    local tmp
    tmp=$(mktemp)
    grep -v "^${key}:" "$config" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$config"
    chmod 600 "$config" 2>/dev/null || true
}

cloudify_vars_deployment_list() {
    local id="${CLOUDIFY_DEPLOYMENT:-}"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set."
    local config
    config=$(_cloudify_deployment_config "$id")
    if [[ ! -f "$config" || ! -s "$config" ]]; then
        [[ "${1:-}" == "--json" ]] && echo "{}" || echo "(no vars)"
        return 0
    fi
    if [[ "${1:-}" == "--json" ]]; then
        echo "{"
        local first=true
        while IFS=: read -r k v; do
            [[ -z "$k" ]] && continue
            k=$(echo "$k" | xargs)  # trim
            v=$(echo "$v" | xargs)
            $first && first=false || echo ","
            printf '  "%s": "%s"' "$k" "$v"
        done < "$config"
        echo
        echo "}"
    else
        cat "$config"
    fi
}

cloudify_vars_deployment_show() {
    local key="$1"
    [[ -n "$key" ]] || die "Usage: cloudify vars show <key>"
    local id="${CLOUDIFY_DEPLOYMENT:-}"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set."
    local config
    config=$(_cloudify_deployment_config "$id")
    [[ -f "$config" ]] || { echo ""; return 0; }
    local val
    val=$(grep "^${key}:" "$config" 2>/dev/null | head -1 | sed "s/^${key}: *//")
    echo "${val:-}"
}

# --- env source (strongest; candidate names only — no ambient var enters) ---

# cloudify_vars_env_read <name...> — claim names present in the caller env.
cloudify_vars_env_read() {
    local print="" name
    [[ -z "${_CLOUDIFY_VARS_LEDGER:-}" ]] && print=1
    for name in "$@"; do
        [[ -n "$name" ]] || continue
        [[ -n "${!name:-}" ]] || continue
        _cloudify_vars_claim "$name" || continue
        [[ -n "$print" ]] && echo "$name"
        export "$name"="${!name}"
    done
}

# --- legacy public aliases (R7) ---

cloudify_vars_set() { cloudify_vars_deployment_write "$@"; }
cloudify_vars_delete() { cloudify_vars_deployment_delete "$@"; }
cloudify_vars_list() { cloudify_vars_deployment_list "$@"; }
cloudify_vars_show() { cloudify_vars_deployment_show "$@"; }
_cloudify_deployment_read_vars() { cloudify_vars_deployment_read "$@"; }

# --- state source (branch 7: replay input, read-only) ---

cloudify_vars_state_read() {
    return 0
}
