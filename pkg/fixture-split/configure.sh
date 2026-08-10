#!/usr/bin/env bash
# Test fixture for install/run split (ADR-008): run phase — no install guard,
# always re-runs (rewrite unit, restart, resolve secrets).

echo "CONFIGURE_RAN token=${K3S_TOKEN:-unset}" >> /tmp/fixture-split-log
