#!/usr/bin/env bash
pkg_verify() {
    # Agent-side join proxy: service active + kubelet client cert issued by the
    # server (created on successful registration). Node Ready is asserted from
    # the server side in the multi-cluster e2e.
    systemctl is-active k3s-agent >/dev/null 2>&1 || return 1
    [[ -f /var/lib/rancher/k3s/agent/client-kubelet.crt ]] || return 1
}
