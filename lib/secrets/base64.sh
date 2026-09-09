#!/usr/bin/env bash
# lib/secrets/base64.sh - built-in base64 secret backend
# Locator is a base64-encoded value (standard alphabet, no padding required to
# survive YAML). Lets a multi-line secret live as one line in a flat file.

# cloudify_secret_backend_base64 <locator>
cloudify_secret_backend_base64() {
    local locator="$1"
    local out
    out=$(printf '%s' "$locator" | base64 -d 2>/dev/null) || {
        log_error "base64 backend: invalid base64 locator."
        return 1
    }
    printf '%s' "$out"
}
