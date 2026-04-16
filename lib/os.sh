#!/usr/bin/env bash
# lib/os.sh - OS detection for cloudify
set -Eeuo pipefail
# Extracted from cloudify monolith

[[ -n "${_CLOUDIFY_OS_LOADED:-}" ]] && return 0
_CLOUDIFY_OS_LOADED=1

function cloudify_osdetect() {
    # Is this Termux on Android?
    local arch
    local kernel
    local os
    local distro
    local distroname
    local lts
    local version

    if [ -n "$(pgrep -f com.termux)" ]; then
        os="android"
        distro="termux"
        version="" # Not needed so far
        lts=""     # Not needed so far
        kernel=""  # Not needed so far
        arch=""    # Not needed so far
    else
        arch=$(uname -m)
        kernel=$(uname -r)

        # Get distribution name
        if [[ -n "$(command -v lsb_release)" ]]; then
            distroname=$(lsb_release -s -d)
        elif [[ -f "/etc/os-release" ]]; then
            distroname=$(grep PRETTY_NAME /etc/os-release | sed 's/PRETTY_NAME=//g' | tr -d '="')
        elif [[ -f "/etc/debian_version" ]]; then
            distroname="Debian $(cat /etc/debian_version)"
        elif [[ -f "/etc/redhat-release" ]]; then
            distroname=$(cat /etc/redhat-release)
        else
            distroname="$(uname -s) $(uname -r)"
        fi
        distroname=$(echo "$distroname" | tr '[:upper:]' '[:lower:]')

        # Get OS
        os=$(uname -o | tr '[:upper:]' '[:lower:]')
        os=${os#gnu/}

        # Get Distribution Version
        distro=$(echo "$distroname" | cut -d' ' -f 1)

        # Get Distribution version
        version=$(echo "$distroname" | cut -d' ' -f 2 | cut -c 1-5)

        # Is it an LTS version?
        lts=$(echo "$distroname" | cut -d' ' -f 3)
    fi

    case "${1:-}" in
    --os)
        echo "$os"
        ;;
    --distro)
        echo "$distro"
        ;;
    --version)
        echo "$version"
        ;;
    --lts)
        echo "$lts"
        ;;
    --arch)
        echo "$arch"
        ;;
    --kernel)
        echo "$kernel"
        ;;
    *)
        echo "$os" "$distro" "$version" "$lts"
        ;;
    esac
}

# Compare two version strings (e.g. "24.04" >= "18.04")
# Usage: cloudify_ver_cmp "24.04" ">=" "18.04"
# Returns 0 if true, 1 if false
# Supports: >=, <=, >, <, ==, !=
function cloudify_ver_cmp() {
    local v1="$1"
    local op="$2"
    local v2="$3"

    # Normalize: strip leading/trailing dots, replace multiple dots
    # Use sort -V (version sort) for comparison
    local result
    if [[ "$op" == "==" ]]; then
        [[ "$v1" == "$v2" ]] && return 0 || return 1
    elif [[ "$op" == "!=" ]]; then
        [[ "$v1" != "$v2" ]] && return 0 || return 1
    fi

    # sort -V returns "newer\nolder" — if v1 is first, v1 >= v2
    result=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)

    case "$op" in
    ">=") [[ "$result" == "$v2" ]] && return 0 || return 1 ;;
    "<=") [[ "$result" == "$v1" ]] && return 0 || return 1 ;;
    ">")  [[ "$result" == "$v2" ]] && [[ "$v1" != "$v2" ]] && return 0 || return 1 ;;
    "<")  [[ "$result" == "$v1" ]] && [[ "$v1" != "$v2" ]] && return 0 || return 1 ;;
    *)    return 2 ;;
    esac
}
