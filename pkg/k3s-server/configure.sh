#!/usr/bin/env bash
# k3s-server — run phase (ADR-008 split): config.yaml + systemd unit + restart.
# No install guard — re-runnable for token rotation / config changes.
# Reads K3S_TOKEN from env (forwarded via .remote-vars, ADR-007).

if [[ -z "${K3S_TOKEN:-}" ]]; then
    log_warn "K3S_TOKEN is unset — the server will generate its own token and agents cannot join."
fi

# Resolve THIS node's tailscale identity (spike: nodes must advertise the ts IP).
TS_IP="$(tailscale ip -4 2>/dev/null | awk '{print $1}')"
[[ -n "$TS_IP" ]] || die "tailscale IPv4 not found — is tailscale up on this node?"
TS_DNS="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName' 2>/dev/null | sed 's/\.$//')"
[[ -n "$TS_DNS" && "$TS_DNS" != "null" ]] || TS_DNS="$(hostname)"

mkdir -p /etc/rancher/k3s

# --- config.yaml: the two REQUIRED flags (ADR-010) are load-bearing ---
cat > /etc/rancher/k3s/config.yaml <<EOF
flannel-iface: tailscale0
node-ip: ${TS_IP}
node-external-ip: ${TS_IP}
tls-san: ${TS_DNS}
cluster-init: true
kubelet-arg:
  - feature-gates=KubeletInUserNamespace=true
kube-apiserver-arg:
  - feature-gates=KubeletInUserNamespace=true
EOF
if [[ -n "${K3S_TOKEN:-}" ]]; then
    echo "token: ${K3S_TOKEN}" >> /etc/rancher/k3s/config.yaml
fi

# NOTE: do NOT overwrite /var/lib/rancher/k3s/server/token here. k3s encrypts
# its etcd bootstrap data with a key derived from that token; changing it on a
# running cluster fatally fails on restart ("encrypted with different token").
# Rotation requires re-bootstrap — see ROADMAP "cloudify configure re-run
# validation". The config.yaml token only applies at first bootstrap; on an
# existing datastore a changed config token is safely ignored.

# --- systemd unit ---
cat > /etc/systemd/system/k3s.service <<'UNIT'
[Unit]
Description=Lightweight Kubernetes (k3s-server)
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target tailscaled.service

[Service]
Type=notify
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/k3s server --config /etc/rancher/k3s/config.yaml
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
systemctl enable k3s.service >/dev/null 2>&1 || true
systemctl restart k3s.service

log_info "k3s-server configured (ip ${TS_IP}, dns ${TS_DNS}). Service restarted."
