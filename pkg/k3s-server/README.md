# k3s-server

[k3s](https://k3s.io) server node — the control plane of a k3s cluster (one server for the MVP single-server topology). Split pkg (ADR-008): `install.sh` downloads the binary + airgap images, `configure.sh` writes `config.yaml` + the systemd unit and starts the service.

## Install

```bash
# one server per cluster; nodes carry a per-cluster tailnet tag (mesh + operator grants)
K3S_TOKEN=<cluster-token> cloudify --on <node> install k3s-server
```

## Configuration

| Var | Required | Description |
|-----|----------|-------------|
| `K3S_TOKEN` | yes | Cluster join token — agents must use the same value. Can come from a deployment: `cloudify deployment create <c>` + `vars set K3S_TOKEN <t>` + `CLOUDIFY_DEPLOYMENT=<c>` |
| `K3S_VERSION` | no | k3s release tag (default `v1.33.3+k3s1`) |

## Behavior & gotchas

- **Two flags are automatic and load-bearing** (ADR-010, spike-proven): `--flannel-iface=tailscale0` (else flannel uses the bridge IP → 100% pod loss) and `--kubelet-arg=feature-gates=KubeletInUserNamespace=true` (else kubelet crashes on `/dev/kmsg` in unprivileged incus).
- **Token rotation is NOT supported** on a running single-server cluster: k3s encrypts its etcd bootstrap data with a key derived from the token; changing it fatally fails on restart ("encrypted with different token"). The old `configure` rotation block was removed for this reason (see ROADMAP "cloudify configure re-run validation").
- **Exposure**: the node's tailnet name is the cluster API endpoint (`https://<server>.komodo-everest.ts.net:6443`); reach it from the operator via the per-cluster grants. To serve an app, `tailscale serve` on the node → clean HTTPS URL.
- Cluster isolation: per-cluster tag (`cluster-<name>`) + mesh grant (`tag:cluster-<name> → same, ports 6443,8472`); operators reach nodes via `tag:workstation` (must exist on a real device) — see ivps HISTORY 2026-08-10.

## Verify

`kubectl get nodes` shows the server node Ready at its tailscale IP (see `verify.sh`).
