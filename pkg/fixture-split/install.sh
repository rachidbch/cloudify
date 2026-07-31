#!/usr/bin/env bash
# Test fixture for install/run split (ADR-008): install phase with install guard.

# --- Install guard ---
if [[ -f /tmp/fixture-split-installed ]] && \
   [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    echo "INSTALL_SKIPPED" >> /tmp/fixture-split-log
    return 0
fi

echo "INSTALL_RAN" >> /tmp/fixture-split-log
touch /tmp/fixture-split-installed
