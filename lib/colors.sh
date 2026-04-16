#!/usr/bin/env bash
# lib/colors.sh - Color setup for cloudify messages
set -Eeuo pipefail
# Extracted from cloudify monolith

[[ -n "${_CLOUDIFY_COLORS_LOADED:-}" ]] && return 0
_CLOUDIFY_COLORS_LOADED=1

# Setup colors codes for more readable messages
function cloudify_setup_colors() {
    # Setup color codes if we have real terminal on stderr unless colors have been disabled
    if ! ${CLOUDIFY_DISABLE_COLORS} && (${CLOUDIFY_FORCE_COLORS:-false} || { [[ -t 2 ]] && [[ "${TERM-}" != "dumb" ]]; }); then
        RESET='\033[0m'
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        ORANGE='\033[0;33m'
        BLUE='\033[0;34m'
        PURPLE='\033[0;35m'
        CYAN='\033[0;36m'
        YELLOW='\033[1;33m'
    else
        RESET=''
        RED=''
        GREEN=''
        ORANGE=''
        BLUE=''
        PURPLE=''
        CYAN=''
        YELLOW=''
    fi
    export RESET RED GREEN ORANGE BLUE PURPLE CYAN YELLOW
}
