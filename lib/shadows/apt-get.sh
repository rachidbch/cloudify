#!/usr/bin/env bash
# lib/shadows/apt-get.sh - Shadow function for apt-get and apt (idempotency, auto-update, -y)
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_SHADOW_APT_GET_LOADED:-}" ]] && return 0
_CLOUDIFY_SHADOW_APT_GET_LOADED=1

# Check if apt cache is stale (older than 60 minutes)
_cloudify_apt_cache_stale() {
    [[ ! -f /var/cache/apt/pkgcache.bin ]] && return 0
    [[ -z "$(find /var/cache/apt/pkgcache.bin -mmin -60)" ]] && return 0
    return 1
}

# Check if a deb package is already installed
_cloudify_pkg_installed() {
    local pkgname="$1"
    dpkg -l "$pkgname" 2>/dev/null |& grep -q "^ii  $pkgname"
}

# Extract package name from a .deb file path or package name
_cloudify_deb_to_pkgname() {
    local pkg="$1"
    if [[ "$pkg" == *.deb ]] && [[ -f "$pkg" ]]; then
        basename "$pkg" | sed 's/\..*$//'
    else
        echo "$pkg"
    fi
}

# Shadow apt-get — adds idempotency, auto-update, -y
# SC2032/SC2033: shadow function calls real binary via sudo — by design
# shellcheck disable=SC2032,SC2033
function apt-get() {
    case "${1:-}" in
    install)
        shift
        # Auto-update if cache stale
        _cloudify_apt_cache_stale && sudo apt-get -q update
        # Install each package with idempotency check
        local pkg pkgname
        for pkg in "$@"; do
            [[ "$pkg" == "-y" || "$pkg" == "--yes" || "$pkg" == -* ]] && continue
            pkgname=$(_cloudify_deb_to_pkgname "$pkg")
            if _cloudify_pkg_installed "$pkgname"; then
                PKG_DEBUG "$pkgname already present"
            else
                sudo apt-get -q install "$pkg" -y
            fi
        done
        ;;
    update)
        shift
        if [[ "${1:-}" == "--force" ]] || _cloudify_apt_cache_stale; then
            sudo apt-get -q update
        fi
        ;;
    remove | purge)
        sudo apt-get "$@"
        ;;
    *)
        sudo apt-get "$@"
        ;;
    esac
}

# apt delegates to apt-get shadow
function apt() { apt-get "$@"; }
