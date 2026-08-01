#!/usr/bin/env bash
pkg_verify() {
    # The server node must be Ready and advertise its tailscale IP (spike req).
    local nodes
    nodes=$(/usr/local/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null) || return 1
    echo "$nodes" | grep -q " Ready " || return 1
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null | awk '{print $1}')
    [[ -n "$ts_ip" ]] && echo "$nodes" | grep -q "$ts_ip" || return 1
}
