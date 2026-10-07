# octop

Self-hosted AI assistant (github.com/TencentCloud/Octop, PyPI `octop`):
single process serving the web dashboard, CLI, IM channels and cron. All
state under `~/.octop/` (SQLite control plane, workspaces, secrets).

## How it is deployed

- **Install**: the official installer script, version-pinned
  (`OCTOP_VERSION`, default `1.0.1`) provisions an isolated uv-managed
  Python 3.12 venv under `~/.octop/` with a `~/.octop/bin/octop` wrapper.
  No system Python is touched. NOTE: 1.0.2b* versions are NOT installable
  by the official installer today - it passes `--prerelease=explicit` for
  b/rc versions, which rejects a transitive prerelease pin
  (`opentelemetry-semantic-conventions==0.54b1`) on every index. 1.0.1 is
  the newest installable version; bump when upstream fixes the flag or
  ships a stable 1.0.2.
- **First boot**: no credentials transit cloudify. The server's setup-wizard
  flow mints a one-time password into `~/octop-login.txt` (printed by the
  install banner); the operator opens the dashboard, pastes it, and creates
  the admin with their own username/password. The file self-removes after
  use. NOTE: CLI `octop init` CANNOT be used post-install - it demands an
  empty `OCTOP_HOME`, but the installer puts the venv there, and its
  `--force` wipes the venv. Never call it.
- **Service**: Octop's own `octop service start` registers the systemd
  **user** unit `octop` (+ a `LimitNOFILE` drop-in it manages). The unit
  file is Octop-owned; recipes never hand-write or rewrite it - upgrades
  that only restart still come back (upstream design).
- **Configure**: upserts `OCTOP_PORT`, `OCTOP_BIND_HOST`,
  `OCTOP_LOG_LEVEL` into `~/.octop/env` (0600) - the dotenv the server
  itself loads at start; env overrides `config.json`. Foreign keys in that
  file (dashboard-set API keys) are preserved: upsert, never replace. Then
  `octop service restart` (only when something changed) and a health probe.
- **Verify**: `systemctl --user is-active octop` + public `GET /health`
  answering `{"status":"ok",...}`.
- **Uninstall**: stops/disables the unit, removes unit + drop-in, keeps
  `~/.octop` (data). `--clear-data` removes `~/.octop` entirely - a wiped
  admin is a dead admin, the next install re-inits.

## Knobs (see `.remote-vars`)

- `OCTOP_VERSION` (1.0.2b6) - pinned PyPI version the installer deploys.
- `OCTOP_PORT` (8088) - listen port.
- `OCTOP_BIND_HOST` (127.0.0.1) - `0.0.0.0` for tailnet/LAN reachability.
- `OCTOP_LOG_LEVEL` (info) - debug|info|warning|error.

## Knobs removed

No `OCTOP_ADMIN_*`: admin creation is the dashboard setup wizard (one-time
  password printed at first boot), never a cloudify variable.

## Gotchas

- Upgrades: installer is skipped when the wrapper exists; to move to a new
  `OCTOP_VERSION` run `--clear-data` install (state is wiped) or run
  `octop update` on the host manually (in-place, Octop-owned).
- The dashboard writes `~/.octop/env` too (Advanced -> Environment
  variables); its save replaces the file - configure re-upserts ours after.
- Browser automation (Playwright Chromium) is NOT installed by default
  (installer `--extras browser`); add it on the host when needed.
- IM channels, connectors and model providers are configured in the
  dashboard, not by this package.

## Backup contract

Cloudify writes no backups. Everything that matters lives in `~/.octop/`
(`octop.db`, `secrets/`, `agents/`, `env`, `config.json`). An external
process owns what to copy and how often; watch for: `octop.db` growth,
`secrets/jwt_secret` rotation (`octop admin rotate-jwt-secret` invalidates
old copies), and `agents/*/` workspace churn.
