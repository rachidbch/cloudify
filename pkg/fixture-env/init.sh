#!/usr/bin/env bash
# Test fixture for pkg .remote-vars (ADR-007): records the K3S_TOKEN value the
# remote host received via env forwarding. Not a real package — used by
# tests/integration/package-remote-vars.bats (parallel two-host forwarding).

echo "${K3S_TOKEN:-UNSET}" > /tmp/cloudify-env-forwarded
