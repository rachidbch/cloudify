# piface

[Piface](https://github.com/jbn/piface) — web UI for `pi` (the terminal coding agent). Wraps one or more `pi --mode rpc` subprocesses behind a FastAPI + WebSocket backend and a Svelte frontend, usable from any browser over Tailscale/VPN.

## Install

```bash
cloudify --on <host> install piface
```

Stack:

- **node** (mise) → `npm install -g @mariozechner/pi-coding-agent` — the `pi` agent piface drives (badlogic/pi-mono, not the host's pi)
- **uv** (standalone) → `uv tool install --python 3.12 piface` — PyPI wheel bundles the built Svelte frontend, so no node/pnpm build step
- **ffmpeg** (apt) — audio conversion for the transcribe endpoint

Runs as a **systemd user service** on `0.0.0.0:7832` (linger enabled, survives logout). The public bind is safe: access is gated at the tailnet boundary (Tailscale Service or `tailscale serve`), not at the host.

## Configuration

Vars live in `~/.config/cloudify/pkgs/piface.yaml`:

| Var | Default | Description |
|-----|---------|-------------|
| `PIFACE_PORT` | `7832` | Server port |
| `PIFACE_HOST` | `0.0.0.0` | Bind address |

## Provider API keys (do this before first use)

Piface's UI picks **which** provider/model to run — it never stores keys. Credentials live in pi's own `~/.pi/agent/auth.json` (0600). pi resolves `auth.json` key → provider env var → none.

**Interactive (preferred):**

```bash
ssh -t root@<host> pi      # -t allocates the TTY pi's TUI needs
```

Then `/login`, pick a provider. Supports OAuth (ChatGPT Plus/Pro Codex, Claude Pro/Max, GitHub Copilot) and API keys. No restart needed — pi re-reads `auth.json` on each session spawn.

**Non-interactive (scripts/CI):** the recipe installs `piface-set-key` (`/usr/local/bin/`):

```bash
ssh root@<host> piface-set-key anthropic sk-ant-...
ssh root@<host> piface-set-key --list
ssh root@<host> piface-set-key cloudflare-ai-gateway cf-token --env CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_GATEWAY_ID=...
```

It does not cover `/login`'s OAuth or shell-command keys (`!op read ...`) — use `/login` when a TTY is available.

## Exposing on Tailscale

Two options; pick by URL preference and durability needs.

**`tailscale serve` (nicest URL, node-bound):**

```bash
ssh root@<host> 'tailscale serve --bg --https 443 http://localhost:7832'
```

→ `https://<hostname>.<tailnet>.ts.net`. Tailnet-only HTTPS (secure context — browser mic/TTS work). Survives reboots; tied to that node — re-run if you recreate the container.

**VIP Service (stable endpoint, decoupled from node):**

```bash
ivps expose-service <remote>:<container> <svc-name> 7832 --tags tag:incus
```

Use a service name that does **not** collide with the container's hostname (Tailscale rejects `svc:<name>` if a node named `<name>` already exists). Then approve at `https://login.tailscale.com/admin/services` and grant access in the ACL.

## Gotchas

- **`ssh -t host pi` not finding `pi`** — mise `activate` lives in `.bashrc`, which Debian early-returns for non-interactive shells. The recipe symlinks the mise shim to `/usr/local/bin/pi` so `pi` resolves in every shell mode (interactive, `bash -c`, systemd). If `pi` ever stops resolving, re-run that symlink.
- **Provider/model list empty on first load** — piface warms it by spawning a `pi --mode rpc --no-session` probe; that probe needs at least one key set, or the dropdown stays empty.
- **Speech/TTS extras** — not installed (they pull torch + need a GPU). Add via `uv sync --extra speech|tts` on a GPU host if wanted.

## Management

```bash
ssh root@<host> 'systemctl --user {status,restart,stop} piface'
ssh root@<host> 'journalctl --user -u piface -f'     # logs
ssh root@<host> 'uv tool upgrade piface && systemctl --user restart piface'   # upgrade
```
