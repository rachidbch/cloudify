#!/usr/bin/env bash
# notes: release links
#   - latest()  Linux 64 : https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-x86_64.sh

# --- Install guard ---
if command -v conda >/dev/null 2>&1 && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "miniconda3 already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Clear data if requested ---
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    log_info "Clearing miniconda3 data..."
    rm -rf "$HOME/miniconda3"
fi

# download bat deb in ~/workstation/install/deb
curl -LSs "https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-x86_64.sh" > miniconda3.sh

# install miniconda3
# shellcheck disable=SC1091 # file is created at runtime by curl on line above
source ./miniconda3.sh
