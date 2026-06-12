#!/usr/bin/env bash
# lib/pkg-config.sh - Package-specific configuration from user files
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_PKG_CONFIG_LOADED:-}" ]] && return 0
_CLOUDIFY_PKG_CONFIG_LOADED=1

# Parse a flat key: value YAML file and export each key as an env var.
# Overrides existing env vars (package config is authoritative).
# No-op if the file doesn't exist.
#
# Supported format:
#   KEY: value
#   KEY: "quoted value"
#   KEY: 'quoted value'
#   # comments
#
# Handles values containing colons (e.g. URLs, ports in strings).
function _cloudify_load_yaml_vars() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        # Split on first ':'
        local key="${line%%:*}"
        local value="${line#*:}"

        # Trim whitespace
        key="${key## }"; key="${key%% }"

        # Validate key is a valid env var name (uppercase + underscores)
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue

        # Trim and strip quotes from value
        value="${value## }"; value="${value%% }"
        value="${value#\"}"; value="${value%\"}"
        value="${value#\'}"; value="${value%\'}"

        export "$key"="$value"
    done < "$file"
}
