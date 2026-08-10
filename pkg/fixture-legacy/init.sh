#!/usr/bin/env bash
# Test fixture for install/run split back-compat (ADR-008): init.sh only —
# must behave exactly as today (no configure phase).

echo "LEGACY_INIT_RAN" >> /tmp/fixture-legacy-log
