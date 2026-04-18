#!/usr/bin/env bash
# lib/shadow.sh - Thin loader for shadow modules
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_SHADOW_LOADED:-}" ]] && return 0
_CLOUDIFY_SHADOW_LOADED=1

##  Cloudify shadows some bash commands and programs to ensure seamless operations (auto-authentication, idempotence, etc)
##  This way, package recipe scripts can be naive bash scripts while cloudify ensures high reliability, remote execution, etc

for _shadow_file in "$CLOUDIFY_SCRIPT_DIR/lib/shadows/"*.sh; do
    # shellcheck source=/dev/null
    [[ -f "$_shadow_file" ]] && source "$_shadow_file"
done
unset _shadow_file
