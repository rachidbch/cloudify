#!/usr/bin/env bash
# lib/containers.sh - Thin ivps abstraction for container operations
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_CONTAINERS_LOADED:-}" ]] && return 0
_CLOUDIFY_CONTAINERS_LOADED=1

# Check that ivps is available in PATH
# Usage: cloudify_require_ivps
function cloudify_require_ivps() {
    command -v ivps >/dev/null || die "ivps is not installed. Cannot perform container operations."
}

# Launch a container via ivps
# Usage: cloudify_container_launch <name> [image] [args...]
function cloudify_container_launch() {
    cloudify_require_ivps
    local name="$1"
    shift || true
    ivps launch "$name" "$@"
}

# Delete a container via ivps
# Usage: cloudify_container_delete <name> [args...]
function cloudify_container_delete() {
    cloudify_require_ivps
    local name="$1"
    shift || true
    ivps delete "$name" "$@"
}

# Get container IPv4 address via ivps
# Usage: cloudify_container_ip <name>
function cloudify_container_ip() {
    cloudify_require_ivps
    ivps ip "$1"
}

# Get container IPv6 address via ivps
# Usage: cloudify_container_ipv6 <name>
function cloudify_container_ipv6() {
    cloudify_require_ivps
    ivps ip "$1" --family inet6
}
