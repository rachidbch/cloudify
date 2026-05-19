#!/usr/bin/env bash

# --- Install guard ---
if command -v ufw >/dev/null 2>&1 && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "ufw already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi

apt-get install -y ufw
sudo ufw allow OpenSSH
sudo ufw enable
