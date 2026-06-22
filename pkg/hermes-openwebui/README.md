# hermes-openwebui

Connects [Open WebUI](https://github.com/open-webui/open-webui) to a [Hermes](https://hermes-agent.nousresearch.com/) agent across separate Incus containers via Tailscale MagicDNS.

## Architecture

```
Container: openwebui-hermes          Container: hermes (or hermes-svc)
┌──────────────────────────┐         ┌──────────────────────┐
│ Docker: open-webui       │         │ hermes agent         │
│ dns: 100.100.100.100     │ MagicDNS│ :8642 (127.0.0.1)   │
│      + <public fallback> │───────→│ tailscale serve :443 │
│ OPENAI_API_BASE_URL:     │         └──────────────────────┘
│  https://<node>...ts.net │
└──────────────────────────┘
```

- **Docker DNS** = dual `100.100.100.100` (Tailscale MagicDNS, resolves `*.ts.net`) + a public fallback (default `1.1.1.1`). quad100 SERVFAILs public domains in this tailnet, so the fallback is required; glibc/musl fail over on SERVFAIL. See `pkg/open-webui/README.md` for the full rationale.
- **Backend node must be a visible tailnet peer**: MagicDNS only resolves peers the ACL lets this node see. If `getent hosts <node>.ts.net` returns NXDOMAIN from the host, fix the Tailscale ACL, not the compose file.
- **Hermes agent** binds `127.0.0.1` only — only `tailscale serve` can reach it
- **No Caddy, no hardcoded IPs, no UFW rules** — just MagicDNS + auto-TLS

## Prerequisites

1. Hermes agent running on a separate container with API server enabled and `tailscale serve`
2. Open WebUI container created: `ivps launch openwebui-hermes`
3. Credentials on the open-webui container:

```bash
ssh openwebui-hermes "mkdir -p ~/.config/cloudify/pkgs"
ssh openwebui-hermes "cat > ~/.config/cloudify/pkgs/hermes-openwebui.yaml <<'EOF'
CLOUDIFY_HERMES_API_URL: 'https://hermes.komodo-everest.ts.net/v1'
CLOUDIFY_HERMES_API_KEY: 'sk-...'
EOF"
```

Get the API key from the hermes container: `ssh hermes 'grep API_SERVER_KEY ~/.hermes/.env'`

## Install

```bash
# Put credentials in ~/.config/cloudify/pkgs/hermes-openwebui.yaml, then:
cloudify --on openwebui-hermes install hermes-openwebui
```

This installs open-webui (Docker) and wires it to Hermes in one step.
Credentials flow from your local `~/.config/cloudify/pkgs/hermes-openwebui.yaml`
through the remote payload into the compose file automatically.

## Configuration

Put these in `~/.config/cloudify/pkgs/hermes-openwebui.yaml` to override defaults:

| Var | Default | Description |
|-----|---------|-------------|
| `CLOUDIFY_HERMES_API_URL` | (required) | Hermes API URL, e.g. `https://hermes.komodo-everest.ts.net/v1` |
| `CLOUDIFY_HERMES_API_KEY` | (required) | Hermes API key (`sk-...`) |
| `WEBUI_ADMIN_EMAIL` | `changeme@example.com` | Open WebUI admin email |
| `WEBUI_ADMIN_PASSWORD` | `changeme` | Open WebUI admin password |

Get the API key from the hermes container: `ssh hermes 'grep API_SERVER_KEY ~/.hermes/.env'`

To change credentials, edit the yaml and re-run with `--force` (bypasses install guard):

```bash
cloudify --on <host> --force install hermes-openwebui
```

The compose file is regenerated with the new values and open-webui restarts automatically.

## Dashboard Access

The Hermes dashboard runs on `127.0.0.1:9119` (loopback only) on the hermes container.
Access it via SSH tunnel:

```bash
ssh -L 9119:127.0.0.1:9119 hermes
# Then open http://localhost:9119
```

## Troubleshooting

**"CLOUDIFY_HERMES_API_KEY is not set":**
Ensure both credentials are in `~/.config/cloudify/credentials` on the open-webui container.

**"Hermes API not reachable":**
Verify the API server is running on the hermes container:
```bash
ssh hermes 'curl -sf http://127.0.0.1:8642/health'
```

**Docker can't resolve MagicDNS hostname:**
First confirm the backend node is a *visible* tailnet peer from this host (MagicDNS only resolves visible peers; ACLs gate visibility):
```bash
getent hosts hermes.komodo-everest.ts.net   # NXDOMAIN = ACL/visibility problem, NOT dns
```
If it resolves on the host but not in the container, check the `dns` block in `/opt/open-webui/docker-compose.yml` (auto-emitted when `OPENAI_API_BASE_URL` is a `*.ts.net` URL):
```yaml
dns:
  - 100.100.100.100
  - 1.1.1.1
```

**View logs:**
```bash
journalctl -u open-webui -f
docker -H /var/run/docker.sock compose -f /opt/open-webui/docker-compose.yml logs
```

## Verification

`verify.sh` is **branch-aware** (no hardcoded endpoints):

- Open WebUI health: `curl http://127.0.0.1:${CLOUDIFY_OPENWEBUI_PORT:-3000}/health`.
- Hermes API health:
  - **Remote mode** (`CLOUDIFY_HERMES_API_URL` set): `curl ${CLOUDIFY_HERMES_API_URL%/}/health`.
  - **Local mode** (unset): reads `API_SERVER_PORT` from `~/.hermes/.env`.

This package **owns** the Hermes API connection check (deep-verify contract b):
it wires Open WebUI to the API, so it verifies that wiring. The base `hermes`
package has no `verify.sh` for the gateway.
