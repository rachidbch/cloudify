#!/usr/bin/env bash
# lib/pkg-config.sh - Package-specific configuration from user files
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_PKG_CONFIG_LOADED:-}" ]] && return 0
_CLOUDIFY_PKG_CONFIG_LOADED=1

# The flat-YAML reader (_cloudify_load_yaml_vars) lives in lib/vars.sh, next to
# the five-source helpers it feeds. Sourced here so tests/consumers that only
# need package config get the reader without loading the whole router.
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vars.sh"
