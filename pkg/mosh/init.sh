#!/usr/bin/env bash
# Mosh server

# --- Install guard ------------------------------------------------------------
if command -v mosh >/dev/null 2>&1 \
   && [[ -z "${CLOUDIFY_FORCE:-}" ]] \
   && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "mosh already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi

# Install mosh
pkg_apt_install mosh

# Disable verbose login (the login message messes w/ mosh protocol)
touch ~/.hushlogin

# Configure and generate UTF-8 locale if not already present
if ! locale -a 2>/dev/null | grep -qi 'en_US.utf'; then
    sudo locale-gen en_US.UTF-8
fi
