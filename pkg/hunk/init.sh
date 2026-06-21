#!/usr/bin/env bash
# hunk — review-first terminal diff viewer for agentic coders
# https://github.com/modem-dev/hunk
# Installs the `hunkdiff` npm package globally (binaries: hunk, hunkdiff).

pkg_depends node

# --- Install guard ------------------------------------------------------------
if command -v hunk >/dev/null 2>&1 \
   && [[ -z "${CLOUDIFY_FORCE:-}" ]] \
   && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "hunk already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Install ------------------------------------------------------------------
npm install -g hunkdiff
