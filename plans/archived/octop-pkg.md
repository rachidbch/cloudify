# Plan: Octop package + first runbook-driven deployment

Goal: deploy https://github.com/TencentCloud/Octop (self-hosted AI assistant,
Python, PyPI `octop`) the proper way - systemd service, docs-read - on a new
instance `octop` on the cloudstation node, through the runbook machinery
(`cloudify app run`), exercising install/configure/verify/uninstall.

## Docs-read decisions (G1 - closed)

- Install: official installer script (`curl .../install.sh | bash -s --
  --version <ver>`), uv-provisioned Python 3.12 venv under `~/.octop/`,
  wrapper `~/.octop/bin/octop`. Version pin `1.0.2b6` (PyPI style arg).
- Service: Octop's own `octop service start` (systemd; we force
  `OCTOP_SERVICE_SCOPE=user`, affine precedent: user unit + linger).
  Octop owns the unit file + LimitNOFILE drop-in; we never hand-write it.
- Config: converge via `~/.octop/env` (dotenv the server itself loads at
  start; env wins over config.json). Upsert keys only, preserve foreign
  keys (dashboard writes the same file; replace-only-ours is the
  non-destructive semantic).
- Unattended init: `octop init` with OCTOP_ADMIN_USERNAME,
  OCTOP_ADMIN_PASSWORD, OCTOP_REQUIRE_SETUP_PASSWORD=false in process env.
  Creds never persisted to disk by the recipe.
- Knobs: OCTOP_PORT (8088), OCTOP_BIND_HOST (127.0.0.1), OCTOP_LOG_LEVEL
  (info), OCTOP_VERSION (1.0.2b6). Health: public `GET /health` ->
  `{"status":"ok",...}`.

## Files

- `pkg/octop/`: `#linux`, `.version` (1.0.0), `.remote-vars`, `install.sh`,
  `configure.sh`, `verify.sh`, `uninstall.sh`, `README.md`.
- `runbooks/octop/default/runbook.md` (targets: server; install/verify
  steps, bare configure fence, teardown step).
- `tests/integration/package-octop.bats` (rubric style, TEST_HOST=cloudify).

## Gates (never skipped)

- G2 L0: shellcheck + bash -n on every recipe file.
- G3 manual ladder on twin `cloudai:octop-twin`: bare install -> health ok;
  configure (bind/port convergence) -> health ok; uninstall clean; then
  `--clear-data` reinstall proves idempotence. Twin torn down after.
- G4 harness once: `task test-integration:octop` green (branch pushed).
- G5 real run: `ivps launch cloudstation:octop`; set deployment values
  (bind 0.0.0.0 for tailnet reachability, admin creds as secret);
  `cloudify app run octop --name main --target server=cloudstation:octop`;
  manifest verified.
- G6 docs: pkg README, HISTORY entry, tree clean, pushed.

## Out of scope

Exposing the dashboard (ivps expose-*), IM channels, browser extras,
PostgreSQL, backups (data under ~/.octop - operator's domain, README
contract).
