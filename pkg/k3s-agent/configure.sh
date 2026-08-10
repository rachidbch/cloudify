#!/usr/bin/env bash
# k3s-agent — run phase (ADR-008 split): config.yaml + systemd unit + restart.
# No install guard — re-runnable for token rotation / server changes.
# Reads K3S_URL + K3S_TOKEN from env (forwarded via .remote-vars, ADR-007).

if [[ -z "${K3S_URL:-}" ]]; then
    die "K3S_URL is required (https://<server>:6443) — set it when calling cloudify install/configure k3s-agent."
fi
if [[ -z "${K3S_TOKEN:-}" ]]; then
    die "K3S_TOKEN is required for the agent to join — set it when calling cloudify install/configure k3s-agent."
fi

# Resolve THIS node's tailscale identity.
TS_IP="$(tailscale ip -4 2>/dev/null | awk '{print $1}')"
[[ -n "$TS_IP" ]] || die "tailscale IPv4 not found — is tailscale up on this node?"

mkdir -p /etc/rancher/k3s

# --- config.yaml: flannel-iface + userns feature gate are REQUIRED (ADR-010) ---
cat > /etc/rancher/k3s/config.yaml <<EOF
server: ${K3S_URL}
token: ${K3S_TOKEN}
flannel-iface: tailscale0
node-ip: ${TS_IP}
node-external-ip: ${TS_IP}
kubelet-arg:
  - feature-gates=KubeletInUserNamespace=true
EOF

# --- systemd unit ---
cat > /etc/systemd/system/k3s-agent.service <<'UNIT'
[Unit]
Description=Lightweight Kubernetes (k3s-agent)
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target tailscaled.service

[Service]
Type=notify
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/k3s agent --config /etc/rancher/k3s/config.yaml
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable k3s-agent.service >/dev/null 2>&1 || true
systemctl restart k3s-agent.service

log_info "k3s-agent configured (server ${K3S_URL}, ip ${TS_IP}). Service restarted."
