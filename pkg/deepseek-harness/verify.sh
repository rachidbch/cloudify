#!/usr/bin/env bash
pkg_verify() {
    # Service must be active (survives reboot via systemd enable) and the Web
    # UI must answer on the configured port.
    systemctl is-active dsh >/dev/null 2>&1 || return 1
    local port="${DSH_PORT:-3080}"
    curl -sf -o /dev/null --max-time 10 "http://127.0.0.1:${port}/" || return 1
}
