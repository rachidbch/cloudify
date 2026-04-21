#!/usr/bin/env bash
# lib/shadows/add-apt-repository.sh - Shadow function for add-apt-repository (idempotency, -y, auto-update)
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_SHADOW_ADD_APT_REPO_LOADED:-}" ]] && return 0
_CLOUDIFY_SHADOW_ADD_APT_REPO_LOADED=1

# Check if an apt repository is already present in sources
_cloudify_repo_present() {
    local check_spec="$1"
    grep -q "^deb .*${check_spec}" /etc/apt/sources.list.d/* 2>/dev/null
}

# Shadow add-apt-repository — adds idempotency, -y, auto-update
# SC2032/SC2033: shadow function calls real binary via sudo — by design
# shellcheck disable=SC2032,SC2033
function add-apt-repository() {
    local repo_spec=""
    local arg
    for arg in "$@"; do
        [[ "$arg" != -* ]] && repo_spec="$arg"
    done
    local check_spec="$repo_spec"
    [[ "$check_spec" == ppa:* ]] && check_spec="${check_spec#ppa:}"
    if _cloudify_repo_present "$check_spec"; then
        PKG_DEBUG "Repository $repo_spec already present"
    else
        sudo add-apt-repository "$repo_spec" -y
        apt-get update --force
    fi
}
