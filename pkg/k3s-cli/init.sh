#!/usr/bin/env bash
# k3s-cli — workstation tooling: kubectl + helm + merged kubeconfig contexts.
# Per-cluster kubeconfig: K3S_SERVER (server's tailscale DNS name) + K3S_CONTEXT
# (context name, e.g. k3s-prod). Install once per cluster, or re-run.

# --- kubectl (skip if present) — user dir, no sudo needed ---
if ! command -v kubectl >/dev/null 2>&1; then
    KUBECTL_VERSION="$(curl -sfL https://cdn.dl.k8s.io/release/stable.txt || echo v1.33.0)"
    curl -sfL -o "${CLOUDIFY_LOCAL_BIN}/kubectl" \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        || die "kubectl download failed"
    chmod +x "${CLOUDIFY_LOCAL_BIN}/kubectl"
fi

# --- helm (skip if present) — user dir via HELM_INSTALL_DIR ---
if ! command -v helm >/dev/null 2>&1; then
    HELM_INSTALL_DIR="$CLOUDIFY_LOCAL_BIN" curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
        || die "helm install failed"
fi

# --- kubeconfig merge (needs K3S_SERVER + K3S_CONTEXT) ---
if [[ -z "${K3S_SERVER:-}" || -z "${K3S_CONTEXT:-}" ]]; then
    log_warn "K3S_SERVER/K3S_CONTEXT unset — kubectl/helm installed, kubeconfig merge skipped."
    return 0
fi

mkdir -p ~/.kube
[[ -f ~/.kube/config ]] || printf 'apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\nusers: []\n' > ~/.kube/config
KCFILE="${HOME}/.kube/k3s-${K3S_CONTEXT}.yaml"
scp -q -o StrictHostKeyChecking=no "root@${K3S_SERVER}:/etc/rancher/k3s/k3s.yaml" "$KCFILE" \
    || die "failed to fetch kubeconfig from ${K3S_SERVER}"

# k3s writes the API server as 127.0.0.1 — point it at the tailscale DNS name.
sed -i "s#server: https://127.0.0.1:6443#server: https://${K3S_SERVER}:6443#" "$KCFILE"

# Context "default" -> per-cluster context name.
kubectl --kubeconfig "$KCFILE" config rename-context default "$K3S_CONTEXT" >/dev/null

# Merge into ~/.kube/config (backup first).
[[ -f ~/.kube/config ]] && cp ~/.kube/config ~/.kube/config.bak
KUBECONFIG="${HOME}/.kube/config:${KCFILE}" kubectl config view --flatten > "${HOME}/.kube/config.new" \
    && mv "${HOME}/.kube/config.new" "${HOME}/.kube/config"

log_info "k3s-cli ready. Use: kubectl --context ${K3S_CONTEXT} get nodes"
