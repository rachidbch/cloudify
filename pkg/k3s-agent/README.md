# k3s-agent

[k3s](https://k3s.io) agent node — a worker that joins a k3s server across the tailnet mesh. Split pkg (ADR-008): `install.sh` downloads the binary, `configure.sh` writes `config.yaml` + the systemd unit and joins.

## Install

```bash
K3S_TOKEN=<cluster-token> K3S_URL=https://<server>.komodo-everest.ts.net:6443 \
  cloudify --on <node> install k3s-agent
```

## Configuration

| Var | Required | Description |
|-----|----------|-------------|
| `K3S_URL` | yes | Server API endpoint (`https://<server-name>:6443`) |
| `K3S_TOKEN` | yes | Cluster join token — must match the server's. Can come from a deployment: `CLOUDIFY_DEPLOYMENT=<c>` + `vars set K3S_TOKEN <t>` |
| `K3S_VERSION` | no | k3s release tag (default `v1.33.3+k3s1`) |

## Behavior & gotchas

- **Two flags are automatic and load-bearing** (ADR-010, spike-proven): `--flannel-iface=tailscale0` (else flannel uses the bridge IP → 100% pod loss) and `--kubelet-arg=feature-gates=KubeletInUserNamespace=true` (else kubelet crashes on `/dev/kmsg` in unprivileged incus).
- **Wrong token → stuck "not authorized"**: the agent retries forever; the server never shows it Ready. The token is single per cluster — rotate at the *server* only via re-bootstrap (rotation unsupported, see k3s-server README).
- Nodes join across the mesh grant (`tag:cluster-<name> → same, ports 6443,8472`); they don't need operator or incus grants.

## Verify

Agent-side: service active + kubelet client cert issued (see `verify.sh`). Node Ready is asserted from the server: `kubectl get nodes`.
