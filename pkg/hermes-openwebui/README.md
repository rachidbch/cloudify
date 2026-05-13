# hermes-openwebui

Connects [Open WebUI](https://github.com/open-webui/open-webui) to a [Hermes](https://hermes-agent.nousresearch.com/) agent, providing a chat UI backed by Hermes.

## What It Does

1. Enables the Hermes API server (sets `API_SERVER_ENABLED=true` in `~/.hermes/.env`)
2. Generates an API key if one doesn't exist (`openssl rand -hex 32`)
3. Configures Open WebUI to use Hermes as its OpenAI-compatible backend
4. Restarts both services as needed

## Prerequisites

- **hermes** package installed and configured (`hermes setup` completed)
- **open-webui** package installed

## Install

```bash
# Ensure Hermes is set up first
hermes setup

# Install Open WebUI
export WEBUI_ADMIN_EMAIL=admin@example.com
export WEBUI_ADMIN_PASSWORD=changeme
cloudify install open-webui

# Connect them
cloudify install hermes-openwebui
```

## How It Works

The install script reads `~/.hermes/.env` and updates `/opt/open-webui/docker-compose.yml` to set:

- `OPENAI_API_BASE_URL=http://host.docker.internal:<port>/v1` — points to the Hermes API server
- `OPENAI_API_KEY=<generated-key>` — the API key for authentication

### Docker-to-Host Networking

Open WebUI runs inside Docker. Hermes runs on the host. The connection crosses a network boundary:

```
Open WebUI (Docker) → host.docker.internal:8642 → Hermes (host process) → LLM API
```

Docker containers can't use `localhost` to reach the host — it means the container itself. `host.docker.internal` resolves to the host's Docker bridge IP (`172.17.0.1`), and is configured in the container via `extra_hosts`.

Two settings make this work:

1. **`API_SERVER_HOST=0.0.0.0`** — Hermes binds all interfaces (default is `127.0.0.1`, unreachable from Docker bridge)
2. **UFW rule** — opens hermes port for Docker bridge subnet only (`172.16.0.0/12`)

If UFW is active (Ubuntu cloud images ship it enabled with deny-all incoming), the install opens the hermes port for the Docker bridge range only. Hermes is not exposed to other networks.

## Reconnecting

If you change the Hermes API server port or key, re-run the connection helper:

```bash
/opt/open-webui/connect.sh
```

This is idempotent — safe to run multiple times.

## Troubleshooting

**"Hermes API server not responding":**
```bash
hermes gateway start
```

**"~/.hermes/.env not found":**
```bash
hermes setup
```

**Open WebUI can't reach Hermes:**
Verify the API server is listening:
```bash
curl http://127.0.0.1:8642/health
```

Check the container can reach the host:
```bash
docker exec open-webui curl -sf http://host.docker.internal:8642/health
```

**View logs:**
```bash
journalctl -u open-webui -f
```
