#!/usr/bin/env bash
# Install mise (polyglot runtime manager: node, python, go, etc.)
# https://mise.jdx.dev

pkg_apt_install curl

# --- Install guard ---
if command -v mise >/dev/null 2>&1 && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "mise already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi

curl -sSL https://mise.run | sh

# shellcheck disable=SC2016 # single quotes are intentional: pkg_in_startuprc writes literal strings to .bashrc
pkg_in_startuprc \
    '## MISE ENV SETUP'\
    'eval "$(~/.local/bin/mise activate bash)"'
