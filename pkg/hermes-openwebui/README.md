# hermes-openwebui

Connects [Open WebUI](https://github.com/open-webui/open-webui) to a [Hermes](https://hermes-agent.nousresearch.com/) agent across separate Incus containers via Tailscale MagicDNS.

## Architecture

```
Container: openwebui-hermes          Container: hermes
┌──────────────────────────┐         ┌──────────────────────┐
│ Docker: open-webui       │         │ hermes agent         │
│ dns: 100.100.100.100     │───────→│ :8642 (127.0.0.1)   │
│ OPENAI_API_BASE_URL:     │ MagicDNS│ tailscale serve :443 │
│  https://hermes...ts.net │         └──────────────────────┘
└──────────────────────────┘
```

- **Docker DNS** = `100.100.100.100` (Tailscale MagicDNS) so containers resolve `hermes.komodo-everest.ts.net`
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
Check the `dns` setting in `/opt/open-webui/docker-compose.yml`:
```yaml
dns:
  - 100.100.100.100
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
