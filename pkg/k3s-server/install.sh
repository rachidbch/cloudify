#!/usr/bin/env bash
# k3s-server — install phase (ADR-008 split): k3s binary + airgap images +
# node prep + install guard. Run phase (config + service) is configure.sh.

# --- Install guard ---
if [[ -x /usr/local/bin/k3s ]] && [[ -d /var/lib/rancher/k3s ]] && \
   [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "k3s already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi

# Pinned, spike-validated (ADR-010). Override with K3S_VERSION env.
K3S_VERSION="${K3S_VERSION:-v1.33.3+k3s1}"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  K3S_ARCH="amd64" ;;
    aarch64) K3S_ARCH="arm64" ;;
    *) die "k3s: unsupported arch $ARCH" ;;
esac

# --- Node prep (best-effort; containers tolerate missing modules) ---
modprobe br_netfilter 2>/dev/null || true
modprobe overlay 2>/dev/null || true
sysctl -w net.bridge.bridge-nf-call-iptables=1 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
swapoff -a 2>/dev/null || true

mkdir -p /var/lib/rancher/k3s/agent/images /etc/rancher/k3s

# --- k3s binary (embeds kubectl + ctr) ---
if [[ ! -x /usr/local/bin/k3s ]]; then
    PKG_DEBUG "Downloading k3s ${K3S_VERSION} (${K3S_ARCH})..."
    curl -sfL -o /usr/local/bin/k3s \
        "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s" \
        || die "k3s binary download failed"
    chmod +x /usr/local/bin/k3s
    /usr/local/bin/k3s --version >/dev/null
fi

# --- Airgap images (best-effort): k3s imports tarballs from this dir on first start.
# If the download fails, the first start pulls images from the registry instead.
if [[ -z "$(ls -A /var/lib/rancher/k3s/agent/images/ 2>/dev/null)" ]]; then
    if curl -sfL --retry 2 -o "/var/lib/rancher/k3s/agent/images/k3s-airgap-images-${K3S_ARCH}.tar.zst" \
        "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-airgap-images-${K3S_ARCH}.tar.zst"; then
        PKG_DEBUG "Airgap images staged for first start."
    else
        rm -f "/var/lib/rancher/k3s/agent/images/k3s-airgap-images-${K3S_ARCH}.tar.zst"
        log_warn "Airgap images download failed — first start will pull from the registry."
    fi
fi

log_info "k3s-server binary installed (${K3S_VERSION}). Run configure to start the service."
