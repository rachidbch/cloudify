# deepseek-harness (dsh)

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) — DeepSeek's open-source agent harness. Everything-is-a-plugin architecture, powered by [Cordis](https://github.com/cordiverse/cordis). Installs the npm package `@deepseek-ai/dsh` and runs its Web UI as a systemd service (survives reboots).

## Install

```bash
cloudify --on <node> install deepseek-harness
```

## Configuration

| Var | Default | Description |
|-----|---------|-------------|
| `DSH_PORT` | `3080` | Web UI port (bound to 127.0.0.1 — expose via tailscale serve, don't rebind) |
| `DSH_TRUSTED_HOST` | auto (node tailnet name) | Host the `/api` browser-trust fence accepts; set when serving via a proxy under another name |

No other vars. The npm `latest` (currently `0.1.0-rc.7`) is pinned at install time; re-run install to bump.

## Expose on the tailnet

```bash
tailscale serve --bg --https=443 http://127.0.0.1:3081   # on the node (nginx relay rewrites Host)
# → https://<node>.komodo-everest.ts.net/
```

## Behavior ## Behavior & gotchas gotchas

- **Loopback API fence**: settings/credentials/llm routes reject any non-loopback Host with 403 (by design; `--trusted-host` only covers the proxy API). The package installs an nginx relay on 127.0.0.1:3081 that rewrites Host AND Origin to 127.0.0.1:3080 (the fence requires both to match the same authority) — tailscale serve must target :3081, or those API calls 403 in the browser.

- **Developer preview**: rapid breaking changes; expect `dsh` CLI/UI drift between versions.
- Node is provided by **mise** (`mise use -g node@lts`) — the systemd `ExecStart` uses the absolute mise shim path captured at install, so the service keeps working after PATH changes.
- `--clear-data` stops + disables the service and wipes `~/.config/dsh` + `~/.local/share/dsh` (XDG candidates), then reinstalls.
- Logs: `journalctl -u dsh -f`.

## Verify

Service active + Web UI answers on `http://127.0.0.1:<port>/` (see `verify.sh`).
