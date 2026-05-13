# open-webui

Standalone [Open WebUI](https://github.com/open-webui/open-webui) via Docker with systemd management.

## Install

```bash
# Works out of the box with defaults:
cloudify install open-webui

# Or override admin credentials:
export WEBUI_ADMIN_EMAIL=admin@example.com
export WEBUI_ADMIN_PASSWORD=mysecurepassword
cloudify install open-webui
```

## Configuration

All configuration is via environment variables set before install. They are written into `/opt/open-webui/docker-compose.yml`.

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLOUDIFY_OPENWEBUI_PORT` | `3000` | Host port to bind |
| `WEBUI_ADMIN_EMAIL` | `changeme@example.com` | Admin email for headless setup |
| `WEBUI_ADMIN_PASSWORD` | `changeme` | Admin password |
| `OPENAI_API_BASE_URL` | (empty) | Backend URL (Ollama, OpenAI, etc.) |
| `OPENAI_API_KEY` | (empty) | Backend API key |

To change configuration after install, edit `/opt/open-webui/docker-compose.yml` and restart:

```bash
systemctl restart open-webui
```

## Service Management

```bash
systemctl status open-webui
systemctl restart open-webui
systemctl stop open-webui
journalctl -u open-webui -f
```

## Usage Examples

### Standalone (no backend)

Access the UI at `http://127.0.0.1:3000`. You can configure backends through the UI settings after login.

### With Ollama (on the same host)

If Ollama is running on the host:

```bash
export WEBUI_ADMIN_EMAIL=admin@example.com
export WEBUI_ADMIN_PASSWORD=changeme
export OPENAI_API_BASE_URL=http://host.docker.internal:11434/v1
cloudify install open-webui
```

The container can reach host services via `host.docker.internal` (configured automatically).

### With Hermes

Use the `hermes-openwebui` package instead — it handles connecting Open WebUI to a Hermes agent automatically.

## Troubleshooting

**Container won't start:**
```bash
journalctl -u open-webui -n 50
docker -H /var/run/docker.sock compose -f /opt/open-webui/docker-compose.yml logs
```

**Port already in use:**
```bash
# Set a different port before installing
export CLOUDIFY_OPENWEBUI_PORT=3001
cloudify install open-webui
```

**Can't reach backend from container:**
The `extra_hosts` directive maps `host.docker.internal` to the host gateway. Use `http://host.docker.internal:<port>` (not `localhost`) in backend URLs. The backend must bind to `0.0.0.0` (not `127.0.0.1`) and the host firewall must allow Docker bridge traffic (`172.16.0.0/12`).

## Data Persistence

All data is stored in `/opt/open-webui/data/` and persists across container restarts.
