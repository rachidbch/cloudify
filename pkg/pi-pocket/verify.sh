#!/usr/bin/env bash
# pkg/pi-pocket - verification hook (sourced in a clean subshell).
# Inputs from env vars (declared names + exported dispatch env), never
# hardcoded endpoints. Three facts prove the app: the unit is active, the
# service listens on its port, and it answers HTTP. The listener check is
# separate from the HTTP check on purpose - a bound port with a failing app
# is drift, not absence.
pkg_verify() {
    local port="${PI_POCKET_PORT:-8787}"
    local service="${PI_POCKET_SERVICE:-pi-pocket}"
    systemctl is-active "$service" >/dev/null 2>&1 || return 1
    ss -tlnp "sport = :${port}" 2>/dev/null | grep -q ":${port}" || return 1
    curl -sf --max-time 5 "http://127.0.0.1:${port}/" >/dev/null || return 1
}
