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
ssh openwebui-hermes "mkdir -p ~/.config/cloudify"
ssh openwebui-hermes "echo 'CLOUDIFY_HERMES_API_URL=https://hermes.komodo-everest.ts.net/v1' >> ~/.config/cloudify/credentials"
ssh openwebui-hermes "echo 'CLOUDIFY_HERMES_API_KEY=sk-...' >> ~/.config/cloudify/credentials"
ssh openwebui-hermes "chmod 600 ~/.config/cloudify/credentials"
```

Get the API key from the hermes container: `ssh hermes 'grep API_SERVER_KEY ~/.hermes/.env'`

## Install

```bash
# 1. Install open-webui on the openwebui-hermes container
cloudify --on openwebui-hermes install open-webui

# 2. Connect it to hermes (reads credentials automatically)
cloudify --on openwebui-hermes install hermes-openwebui
```

## Configuration

Credentials are stored in `~/.config/cloudify/credentials` on the open-webui container:

```bash
CLOUDIFY_HERMES_API_URL=https://hermes.komodo-everest.ts.net/v1
CLOUDIFY_HERMES_API_KEY=sk-...
```

## Reconnecting

If you change the Hermes API key or URL:

```bash
/opt/open-webui/connect-remote.sh
```

This is idempotent — safe to run multiple times.

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
