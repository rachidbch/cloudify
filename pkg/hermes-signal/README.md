# hermes-signal

Signal messaging gateway for [Hermes Agent](https://hermes-agent.nousresearch.com/). Runs [signal-cli-rest-api](https://github.com/bbernhard/signal-cli-rest-api) in Docker as a systemd service, so Hermes can send and receive Signal messages.

## Prerequisites

- **Hermes installed and configured** — `cloudify install hermes` + `hermes setup` (API keys, model)
- **Docker** — installed automatically via `pkg_depends docker`

## Install

```bash
cloudify install hermes-signal
```

This sets up:

- `/opt/signal-gateway/docker-compose.yml` — signal-cli REST API container (json-rpc mode)
- `/opt/signal-gateway/data/` — persistent Signal account data (survives container restarts)
- `/opt/signal-gateway/link-device.sh` — helper to link your phone via QR code
- `hermes-signal-gateway.service` — systemd unit (auto-starts on boot)

The container listens on `127.0.0.1:8080` by default.

## Post-Install Setup

### Step 1: Link your phone

SSH into the host and run:

```bash
/opt/signal-gateway/link-device.sh
```

This displays a QR code in your terminal. On your phone:

1. Open Signal → Settings → Linked Devices
2. Tap **Link New Device**
3. Scan the QR code

The script polls until the link succeeds, then confirms.

### Step 2: Configure Hermes

```bash
hermes gateway setup
```

Select **Signal** from the platform menu. The wizard will:

1. Detect signal-cli at `http://127.0.0.1:8080` (press Enter to accept the default)
2. Ask for your phone number (E.164 format, e.g. `+1234567890`)
3. Ask which users are allowed to message the bot

That's it — Hermes is now reachable on Signal.

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLOUDIFY_SIGNAL_PORT` | `8080` | Port for the signal-cli REST API |

To use a custom port, set it before installing:

```bash
CLOUDIFY_SIGNAL_PORT=9090 cloudify install hermes-signal
```

Access control and other Signal settings are managed through Hermes (`hermes gateway setup` or `~/.hermes/.env`). See the [Hermes Signal docs](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/signal) for the full list of environment variables.

## Service Management

```bash
systemctl status hermes-signal-gateway     # check status
systemctl restart hermes-signal-gateway    # restart container
journalctl -u hermes-signal-gateway -f     # live logs
```

## How It Works

```
Signal servers
     │
     ▼
signal-cli-rest-api (Docker, port 8080)
  - Handles Signal protocol, encryption, linking
  - Exposes JSON-RPC + SSE over HTTP
     │
     ▼
Hermes gateway (hermes-signal adapter)
  - Connects to http://127.0.0.1:8080
  - Streams inbound messages via SSE
  - Sends outbound messages via JSON-RPC
     │
     ▼
Your LLM provider (OpenRouter, Anthropic, etc.)
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Container not starting | `systemctl status hermes-signal-gateway` and check journal |
| QR code won't scan | Maximize your terminal — wrapped lines break the QR code |
| "Cannot reach signal-cli" in hermes setup | Ensure the service is running: `systemctl start hermes-signal-gateway` |
| Messages not received | Check `SIGNAL_ALLOWED_USERS` includes sender's number (E.164 format with `+` prefix) |
| Link device fails after reinstall | Remove old data: `rm -rf /opt/signal-gateway/data/*`, then restart the service and re-link |
