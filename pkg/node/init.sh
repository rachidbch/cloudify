#!/usr/bin/env bash
# node — Node.js runtime (18+) and npm
# Uses mise when present (the host's runtime manager); falls back to system apt.
# Required by JS/TS tools (hunk, tern, ...).

# --- Install guard -----------------------------------------------------------
if command -v node >/dev/null 2>&1 \
   && [[ -z "${CLOUDIFY_FORCE:-}" ]] \
   && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "node already installed ($(node --version)). Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Install -----------------------------------------------------------------
if command -v mise >/dev/null 2>&1; then
    # mise-managed: install LTS globally, consistent with the host's setup.
    mise use -g node@lts
else
    # NOTE: stock Ubuntu/Debian nodejs can lag below 18 (e.g. Ubuntu 22.04 ships
    #       12.x). Tools requiring Node 18+ should ensure mise is installed first.
    pkg_apt_install nodejs npm
fi
