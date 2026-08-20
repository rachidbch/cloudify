# deepseek-harness (dsh)

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) — DeepSeek's open-source agent harness. Everything-is-a-plugin architecture, powered by [Cordis](https://github.com/cordiverse/cordis). Installs the npm package `@deepseek-ai/dsh` and runs its Web UI as a systemd service (survives reboots).

## Install

```bash
cloudify --on <node> install deepseek-harness
```

## Configuration

| Var | Default | Description |
|-----|---------|-------------|
| `DSH_PORT` | `3080` | Web UI port (bound to 127.0.0.1) |
| `DSH_TRUSTED_HOST` | auto (node tailnet name) | Host the `/api` browser-trust fence accepts (proxy API only) |

No other vars. The npm `latest` (currently `0.1.0-rc.7`) is pinned at install time; re-run install to bump.

## Expose on the tailnet

The install runs `tailscale serve` → `127.0.0.1:3081`, which is the **dsh-full-remote** proxy (see below):

```
https://<node>.komodo-everest.ts.net/   # first visit: login form, enter the printed token once
```

## Remote-browser access: dsh-full-remote plugin

dsh's `/api` fence is **loopback-only by design** — settings/credentials/llm routes reject any non-loopback Host/Origin with 403 (`--trusted-host` covers only the proxy API; upstream discussion #1054 confirms no opt-in flag), and the browser additionally refuses the settings UI unless `window.location` is loopback. The intended remote pattern is SSH port-forwarding.

The package installs the community plugin **dsh-full-remote** (pinned `0.3.4`; [repo](https://github.com/JUANWANG-BUAA/dsh-full-remote)) which solves both gates in one maintained, authenticated layer:

- in-process proxy on `127.0.0.1:3081` rewrites Host/Origin to loopback → privileged APIs pass the fence
- **dsh-loopback-pin** (our plugin, shipped in this package) opens the client gate: pins `connection.isLoopback = true` so the settings UI loads from remote browsers. Why it exists: dsh-full-remote's page-bootstrap wraps `loader.load` once, but the shipped runtime reassigns it (thin `registration => this.register(registration)` arrow), silently clobbering the wrap (the marker survives, the wrapper doesn't). Our plugin installs an **accessor** on `loader.load` — getter always returns our intercepting function, setter captures reassignments as the new delegate — and wraps the connection module's factory to pin `isLoopback` right after its apply. Diagnosed live with a headless browser 2026-08-20; survives dsh updates by construction
- **192-bit token + per-device sessions** (login once; HttpOnly SameSite cookie; optional approval mode)

**Risk notes (audited 2026-08-10; pin re-audited 2026-08-20):** third-party plugin (not DeepSeek-official); minimal deps (schemastery + uqr), hand-rolled node:http proxy with hop-by-hop/spoofable-header stripping and loopback-only control routes; published npm artifact matches the reviewed repo. Residual: version drift against fast-moving dsh (pinned; re-audit on upgrades) and the token gate (one-time login per device).

## Behavior & gotchas

- **Developer preview**: rapid breaking changes; expect `dsh` CLI/UI drift between versions.
- Node is provided by **mise** (`mise use -g node@lts`); the systemd `ExecStart` uses the absolute mise shim path captured at install.
- The remote-access **token is printed at install** (also in `~/.dsh/reverse-proxy.json`, 0600). Lost it? Rotate via Settings → Reverse proxy on the local UI, or rewrite the state file + restart dsh.
- `--clear-data` stops + disables the service and wipes `~/.config/dsh`, `~/.local/share/dsh`, `~/.dsh`, then reinstalls.
- Direct local access stays open at `http://127.0.0.1:3080` (loopback-only bind).
- Logs: `journalctl -u dsh -f`.

## Verify

Service active + Web UI answers on `http://127.0.0.1:<port>/` (see `verify.sh`).
