#!/usr/bin/env bash
# Test fixture for the uninstall action: install provisions a marker.

if [[ -f /tmp/fixture-uninstall-marker ]] && \
   [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    echo "INSTALL_SKIPPED" >> /tmp/fixture-uninstall-log
    return 0
fi

echo "INSTALL_RAN" >> /tmp/fixture-uninstall-log
touch /tmp/fixture-uninstall-marker
