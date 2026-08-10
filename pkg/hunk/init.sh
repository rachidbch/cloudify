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
# npm's default global bin dir is invisible to non-login ssh sessions (the
# test container's npm resolves to a stale hermes-era node). Install to a
# private prefix and symlink the binaries into /usr/local/bin (on the ssh
# PATH). Redo both on every run so the guard + PATH stay consistent.
NPM_PREFIX="/opt/hunkdiff"
mkdir -p "$NPM_PREFIX"
npm install -g --prefix "$NPM_PREFIX" hunkdiff
for bin in hunk hunkdiff; do
    ln -sf "$NPM_PREFIX/bin/$bin" "/usr/local/bin/$bin"
done
