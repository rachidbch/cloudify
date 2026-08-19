# k3s-cli

Workstation tooling for the k3s clusters: **kubectl + helm**, plus per-cluster **kubeconfig contexts** merged into `~/.kube/config`. Runs LOCALLY (no `--on`): installs to `~/.local/bin` (no sudo).

## Install

```bash
# once per cluster (repeatable)
K3S_SERVER=<server>.komodo-everest.ts.net K3S_CONTEXT=k3s-<name> cloudify install k3s-cli
```

Then: `kubectl --context k3s-<name> get nodes`

## Configuration

| Var | Required | Description |
|-----|----------|-------------|
| `K3S_SERVER` | no | Server's tailscale DNS name — without it only kubectl/helm install |
| `K3S_CONTEXT` | no | Context name for the kubeconfig merge (e.g. `k3s-prod`) |

## Behavior & gotchas

- **No sudo**: kubectl and helm install to `~/.local/bin` (helm's installer always uses sudo otherwise — `USE_SUDO=false` + process substitution, see git history).
- **Context-specific names**: the merge renames cluster/user/context to `$K3S_CONTEXT` (k3s writes them all as "default"). Re-running against a NEW cluster replaces the stale entry cleanly — no "unknown authority" from old CAs.
- The kubeconfig is fetched from the server over the operator grants (`tag:workstation` must exist on your device — see ivps HISTORY 2026-08-10).
- Back up `~/.kube/config` before first merge (the recipe does it automatically: `config.bak`).
