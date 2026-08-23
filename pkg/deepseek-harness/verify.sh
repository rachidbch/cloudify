#!/usr/bin/env bash
pkg_verify() {
    # Service must be active (survives reboot via systemd enable) and the Web
    # UI must answer on the configured port.
    systemctl is-active dsh >/dev/null 2>&1 || return 1
    local port="${DSH_PORT:-3080}"
    curl -sf -o /dev/null --max-time 10 "http://127.0.0.1:${port}/" || return 1

    # Remote-access state intact (token + sessions) — the update gate: a
    # configure run must never lose these.
    local state="${DSH_HOME:-$HOME/.dsh}/reverse-proxy.json"
    [[ -f "$state" ]] || return 1
    local perms; perms=$(stat -c %a "$state" 2>/dev/null) || return 1
    [[ "$perms" == "600" ]] || return 1
    local tok; tok=$(jq -r '.accessToken // ""' "$state" 2>/dev/null) || return 1
    [[ "$tok" =~ ^[0-9a-f]{64}$ ]] || return 1

    # Composition intact: the served index carries BOTH plugin bootstraps
    # (the proxy + the loopback pin). Catches version drift that silently
    # drops a plugin's patch from the profile after a dsh bump.
    local html; html=$(curl -sf --max-time 10 "http://127.0.0.1:${port}/") || return 1
    [[ "$html" == *'data-plugin="dsh-loopback-pin"'* ]] || return 1
    [[ "$html" == *'data-plugin="dsh-reverse-proxy"'* ]] || return 1
}
