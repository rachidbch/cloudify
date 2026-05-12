# hermes-signal

Signal messaging gateway for [Hermes Agent](https://hermes-agent.nousresearch.com/). Runs [signal-cli-rest-api](https://github.com/bbernhard/signal-cli-rest-api) in Docker as a systemd service, so Hermes can send and receive Signal messages.

## Prerequisites

- **Hermes installed and configured** — `cloudify install hermes` then run `hermes setup` to configure your model provider and API keys
- **Docker** — installed automatically via `pkg_depends docker`

## Install

**On the local machine:**

```bash
cloudify install hermes-signal
```

**On a remote host:**

```bash
cloudify --on myserver install hermes-signal
```

This creates:

| Path | Purpose |
|------|---------|
| `/opt/signal-gateway/docker-compose.yml` | Container definition (signal-cli REST API, json-rpc mode) |
| `/opt/signal-gateway/data/` | Persistent storage — Signal encryption keys, linked device session, account identity. **This directory is the credential store.** If deleted, you must re-link your phone from scratch. |
| `/opt/signal-gateway/link-device.sh` | Helper script to link your phone via QR code |
| `/etc/systemd/system/hermes-signal-gateway.service` | Systemd unit — starts the container, restarts on failure and on boot |

The service starts immediately when install completes (no reboot needed). The container listens on `127.0.0.1:8080` by default.

## Post-Install Setup

After install, you need to link your phone and configure Hermes. There are two ways:

### One-shot (recommended)

SSH into the host and run:

```bash
/opt/signal-gateway/link-device.sh --phone +15551234567
hermes gateway start
```

- `--phone` — your Signal phone number in E.164 format (the one linked to your Signal account). You are automatically added as an allowed user.
- `--invites` — optional. Additional phone numbers allowed to message the bot, comma-separated. Example: `--invites +15559876543,+15551112222`

The script will:

1. Display a QR code in your terminal — scan it with your phone (Signal → Settings → Linked Devices → Link New Device)
2. Wait for the scan to complete (polls the REST API every 3 seconds)
3. Run `hermes config set` to configure the Signal adapter automatically — no wizard needed

### Step by step (interactive)

If you prefer the interactive wizard, or need to set advanced options (group access, home channel):

**Step 1: Link your phone**

```bash
/opt/signal-gateway/link-device.sh
```

Scan the QR code with your phone. The script polls the REST API until the link succeeds.

**Step 2: Configure Hermes**

```bash
hermes gateway setup
```

Select **Signal** from the platform menu. The wizard will:

1. Check that signal-cli is reachable at `http://127.0.0.1:8080` (press Enter to accept the default)
2. Ask for your phone number (E.164 format, e.g. `+1234567890`)
3. Ask which users are allowed to message the bot

See the [Hermes Signal docs](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/signal) for the full list of environment variables you can set manually.

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLOUDIFY_SIGNAL_PORT` | `8080` | Port for the signal-cli REST API (both Docker mapping and systemd service) |

To use a custom port, set it before installing. The variable is forwarded to remote hosts automatically:

```bash
# Local
CLOUDIFY_SIGNAL_PORT=9090 cloudify install hermes-signal

# Remote — works the same way
CLOUDIFY_SIGNAL_PORT=9090 cloudify --on myserver install hermes-signal
```

Hermes-level settings (allowed users, group access, home channel) are managed through `hermes gateway setup` or by editing `~/.hermes/.env` directly. The key variables are:

| Variable | Required | Description |
|----------|----------|-------------|
| `SIGNAL_HTTP_URL` | Yes | signal-cli endpoint (default: `http://127.0.0.1:8080`) |
| `SIGNAL_ACCOUNT` | Yes | Bot phone number in E.164 format |
| `SIGNAL_ALLOWED_USERS` | No | Comma-separated phone numbers/UUIDs who can message the bot |

## Service Management

```bash
# Check if the container is running
systemctl status hermes-signal-gateway

# Start / stop / restart
sudo systemctl start hermes-signal-gateway
sudo systemctl stop hermes-signal-gateway
sudo systemctl restart hermes-signal-gateway

# View live logs
journalctl -u hermes-signal-gateway -f

# View container logs directly
cd /opt/signal-gateway && docker compose logs -f
```

**Common scenarios:**

```bash
# Pull the latest signal-cli image and restart
cd /opt/signal-gateway && docker compose pull && sudo systemctl restart hermes-signal-gateway

# Check if the API is responding
curl -s http://127.0.0.1:8080/v1/about | jq .

# List linked accounts
curl -s http://127.0.0.1:8080/v1/accounts | jq .

# Stop and remove everything (keeps data/)
sudo systemctl stop hermes-signal-gateway
cd /opt/signal-gateway && docker compose down
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| **Container not starting** | `systemctl status hermes-signal-gateway` and `journalctl -u hermes-signal-gateway --no-pager -n 50` |
| **Docker permission denied** | Your user needs docker group: `sudo usermod -aG docker $USER` then `newgrp docker` |
| **QR code won't scan** | Maximize your terminal (at least 80 columns). If lines wrap, the QR code is corrupted and won't scan. |
| **"Cannot reach signal-cli" in hermes setup** | Check the service is running: `systemctl start hermes-signal-gateway`. Then test: `curl http://127.0.0.1:8080/v1/about` |
| **Messages not received** | Check `SIGNAL_ALLOWED_USERS` in `~/.hermes/.env` — must include sender's number in E.164 format (with `+` prefix). Without it, the gateway denies all incoming messages by default. |
| **Link device fails after reinstall** | Old session data conflicts with new container. Remove it: `rm -rf /opt/signal-gateway/data/*`, then `sudo systemctl restart hermes-signal-gateway`, then re-run `link-device.sh` |
| **Container keeps restarting** | Check `docker compose logs` — usually a port conflict (something else on 8080) or corrupt data directory |
| **Hermes gateway disconnects** | The hermes-signal adapter auto-reconnects with exponential backoff. If it stays down, check that the signal-cli container is healthy and the REST API responds at the configured URL. |
| **Bot responds to no one** | Either `SIGNAL_ALLOWED_USERS` is misconfigured, or no users have been approved via DM pairing (`hermes pairing approve signal CODE`). |

## How It Works

When a user sends a Signal message to your bot, here is the full path it takes — and the path the response takes back:

```
USER'S PHONE                                     YOUR SERVER (VPS)
                                          ┌──────────────────────────┐
                                          │                          │
                                          │  Docker container:       │
                                          │  signal-cli-rest-api     │
  Signal ─── Signal protocol ──────────►  │  (port 8080)             │
  app       (end-to-end encrypted)         │                          │
                                          │  Maintains persistent    │
                                          │  connection to Signal    │
                                          │  servers. Receives       │
                                          │  inbound messages and    │
                                          │  exposes them via HTTP.  │
                                          │                          │
                                          └──────────┬───────────────┘
                                                     │
                                                     │ HTTP GET /v1/receive
                                                     │ (SSE — Server-Sent Events)
                                                     │ signal-cli pushes new
                                                     │ messages as JSON events
                                                     ▼
                                          ┌──────────────────────────┐
                                          │  Hermes gateway process  │
                                          │  (hermes-signal adapter) │
                                          │                          │
                                          │  Reads each inbound      │
                                          │  message. Forwards it    │
                                          │  to the LLM with the     │
                                          │  user's conversation     │
                                          │  context.                │
                                          │                          │
                                          └──────────┬───────────────┘
                                                     │
                                                     │ HTTP API
                                                     │ (OpenAI-compatible)
                                                     ▼
                                          ┌──────────────────────────┐
                                          │  LLM provider            │
                                          │  (OpenRouter, Anthropic, │
                                          │   OpenAI, local model…)  │
                                          └──────────┬───────────────┘
                                                     │
                                                     │ LLM response text
                                                     ▼
                                          ┌──────────────────────────┐
                                          │  Hermes gateway          │
                                          │  Sends response back via │
                                          │  HTTP POST (JSON-RPC)    │
                                          │  to signal-cli REST API  │
                                          └──────────┬───────────────┘
                                                     │
                                                     │ HTTP POST /v1/send
                                                     │ (JSON-RPC over HTTP)
                                                     ▼
                                          ┌──────────────────────────┐
                                          │  signal-cli-rest-api     │
                                          │  Encrypts and sends via  │
                                          │  Signal protocol         │
                                          └──────────┬───────────────┘
                                                     │
  Signal ◄── Signal protocol ────────────────────────┘
  app       (end-to-end encrypted)

Interfaces summary:
  - Signal servers ↔ signal-cli: Signal protocol (encrypted, persistent TCP)
  - signal-cli ↔ Hermes: HTTP (SSE for inbound, JSON-RPC for outbound)
  - Hermes ↔ LLM: HTTP (OpenAI-compatible chat completions API)
```

There are three interfaces at play:

1. **Signal servers ↔ signal-cli** (inside the Docker container): The container maintains a persistent encrypted connection to Signal's servers. It acts as a linked device on your account — similar to Signal Desktop.

2. **signal-cli ↔ Hermes gateway** (localhost HTTP): Hermes connects to `http://127.0.0.1:8080`. Inbound messages arrive as **Server-Sent Events (SSE)** — a long-lived HTTP GET where the server pushes JSON events. Outbound messages are sent as **JSON-RPC over HTTP POST**. Both are plain HTTP on localhost (no TLS needed — traffic never leaves the machine).

3. **Hermes gateway ↔ LLM provider** (HTTPS): Hermes calls your configured LLM provider's chat completions API. This is standard HTTPS outbound.
