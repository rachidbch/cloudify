#!/usr/bin/env bash
# Test fixture for the uninstall action: teardown removes the install marker.

echo "UNINSTALL_RAN" >> /tmp/fixture-uninstall-log
rm -f /tmp/fixture-uninstall-marker
