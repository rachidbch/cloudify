# Cloudify — Session History

## 2026-06-11 — Fix open-webui crash, complete separate-containers v2 deployment

- **Root cause:** Docker `dns: [100.100.100.100]` (Tailscale MagicDNS) can't resolve `huggingface.co`, so SentenceTransformer model download fails at boot. Empty `RAG_EMBEDDING_ENGINE=` still triggers default model loading.
- **Fix:** Removed `dns:` section from open-webui recipe (let Docker use host DNS via systemd-resolved stub). Added conditional `RAG_EMBEDDING_ENGINE=openai` when `OPENAI_API_BASE_URL` is set. Updated `connect-remote.sh` to ensure RAG_EMBEDDING_ENGINE is set.
- **Deployed:** open-webui on openwebui-hermes container is healthy (Up, healthy). tailscale serve exposes `https://openwebui-hermes.komodo-everest.ts.net`. API connectivity open-webui → hermes verified.
- **Commit:** ee028af — `pkg/open-webui/init.sh`, `pkg/hermes-openwebui/connect-remote.sh`

## 2026-05-19 — Document and apply install guard convention (E1, E2)

- **E1:** Added "Install Guards" subsection to README.md "Writing a Package Recipe" — documents software vs data distinction, FORCE/CLEAR_DATA vars, code pattern
- **E2:** Audited all 73 packages. Added install guards to 16 stateful packages: hermes-signal, restic, docker, rclone, mise, fzf, sdkman, miniconda3, bash-it, dotfiles, leanmacs, spacemacs, mariadb, mysql, wezterm, ufw
- Converted 4 ad-hoc skip checks to FORCE/CLEAR_DATA convention (mariadb, mysql, wezterm, ufw)
- Fixed inverted fzf clone/pull logic
- Files changed: 16 `pkg/*/init.sh`, `README.md`, `OPTIMIZATIONS.md`
- 237 unit tests pass, 26/27 integration tests pass (open-webui pre-existing flaky test)

## 2026-05-18 — Apply OPTIMIZATIONS.md decisions (A1, B1, C1, D1, A2, G1)

- **A1:** Replaced `exec >> log 2>&1` with `exec > >(tee -a log) 2>&1 </dev/null` in remote payload — output now visible on local terminal AND written to log file
- **B1:** Added `--clear-data` CLI flag → exports `CLOUDIFY_CLEAR_DATA=true`, passed through remote payload. Implies `CLOUDIFY_FORCE=true`
- **C1:** `CLOUDIFY_FORCE=true` set for explicitly dispatched packages; `pkg_depends()` unsets both `CLOUDIFY_FORCE` and `CLOUDIFY_CLEAR_DATA` before sourcing dependency recipes (subshell isolation)
- **D1:** Remote log filename matches local via `CLOUDIFY_LOG_BASENAME`; `ln -sf` creates `/tmp/cloudify/logs/latest.log` symlink after each run
- **A2:** Added `stdbuf -oL` before sed calls in SSH pipeline for line-buffered output
- **G1:** Removed redundant hermes config fixture from integration test; hermes-openwebui test reads auto-generated API key
- Files changed: `cloudify`, `lib/remote.sh`, `lib/package-api.sh`, `OPTIMIZATIONS.md`, `tests/unit/remote.bats`, `tests/unit/packages.bats`, `tests/integration/package-hermes-openwebui.bats`
- All 230 unit tests pass

## 2026-05-18 — Fix hermes gateway TEMPFAIL in integration tests

- Root cause: hermes installer writes 1100-line `config.yaml` with `provider: "auto"` (indented under `model:`).
  The auto-config check `grep -q "^provider:"` never matched the indented YAML, so KeylessAI was never configured.
  Gateway started with no valid API key, tried OpenRouter for 7-14 minutes, then TEMPFAILed.
- Fix: replaced the idempotency check to detect `provider:.*"auto"` pattern and overwrite with KeylessAI config
- File: `pkg/hermes/init.sh`
- All 12 hermes-openwebui integration tests pass

## 2026-05-15 — Shadow system hardening, test infra fixes, hermes auto-config

- Added explicit `/dev/null` stdin detection in shadow sudo (`[[ /dev/stdin -ef /dev/null ]]`)
  to skip `cat -` when stdin is /dev/null (after `exec </dev/null` in remote payload)
- Clarified `exec </dev/null` comment in `lib/remote.sh`: explains why closing stdin is
  needed and why pipelines within recipes still work
- Standardized test passwords: `testpwd` → `dummy` across all test files
- Standardized default admin emails: `admin@example.com` → `changeme@example.com` in READMEs
- Fixed open-webui: `docker compose up --force-recreate` in systemd service so env var
  changes take effect on restart (root cause 2 of env vars not applied)
- Moved `task lint` to run locally with auto-install of shellcheck (no container sync needed)
- Added rsync to `setup-container` task and `tests/run-integration.sh` snapshot provisioning
- Added SSH host key bypass flags to `ensure_snapshot()` in `run-integration.sh`
- Added prominent `--on` argument order note to usage text and CLAUDE.md
- Hermes package auto-configures KeylessAI as default LLM provider (free, no account, no API key).
  Only written if no provider already configured. Users run `hermes model` to switch to paid providers.
- Documented `CLOUDIFY_OPENWEBUI_BIND` in open-webui README for remote/container access
- All 222 unit tests pass, all 27 integration tests pass

## 2026-05-14 — Live remote logging + hermes-openwebui production deploy

- Added `exec >> file 2>&1 </dev/null` in payload template for live remote logging
- `</dev/null` closes stdin so shadow sudo's `cat -` gets EOF instead of blocking on SSH pipe
- Removed `tail -n +2` from local SSH pipe chain (was buffering all output until SSH closed)
- Fixed hermes installer clobbering Python entry point: hermes install.sh wrote bash wrapper
  to venv/bin/hermes via symlink, creating infinite exec loop. Restore correct Python entry
  point (`hermes_cli.main:main`) after installer runs.
- Added `--no-defaults` flag for minimal installs (basics + target only)
- Trimmed `basics` meta-pkg: removed mosh and silversearcher-ag; promoted silversearcher-ag to @default
- Fixed `pkg_depends` unbound variable: moved .script glob inside recipe branch
- Fixed mosh pkg stall: removed fragile `sudo tee` heredoc, made locale-gen idempotent
- Passed `WEBUI_ADMIN_EMAIL`, `WEBUI_ADMIN_PASSWORD`, `CLOUDIFY_OPENWEBUI_BIND` through remote payload
- Deployed hermes-openwebui on hermes prod: gateway healthy, open-webui on 0.0.0.0:3000,
  accessible via Tailscale at 100.106.4.58:3000

## 2026-05-13 — Diagnosed hermes-openwebui connectivity failure

- Ran full integration test suite (11/11 passing) for hermes-openwebui in container
- Both services healthy but Open WebUI shows no models in dropdown
- User confirmed: can login, sees connection URLs in Settings > Connections, but no models
- Read official docs (openwebui.com + hermes-agent.nousresearch.com) to correct mental model
- **Root cause confirmed**: Hermes API server binds to `127.0.0.1:8642` (default `API_SERVER_HOST`). Docker containers reach host via `172.17.0.1` (bridge gateway). Packets from bridge IP hit closed port.
  - `ss -tlnp` shows `LISTEN 127.0.0.1:8642`
  - `curl http://172.17.0.1:8642/health` → connection refused
  - `docker exec open-webui curl http://host.docker.internal:8642/health` → hangs 30s+
- Secondary issues: missing `ENABLE_OLLAMA_API=false`, `ENABLE_PERSISTENT_CONFIG=False` has known bugs
- Proposed fixes: `API_SERVER_HOST=0.0.0.0` in hermes env, `ENABLE_OLLAMA_API=false`, remove `ENABLE_PERSISTENT_CONFIG=False`
- Next: apply fixes to `pkg/hermes-openwebui/`, `pkg/open-webui/`, and update tests

## 2026-05-13 — Fixed hermes-openwebui (3 commits)

- Applied fixes to `pkg/hermes-openwebui/init.sh`: set `API_SERVER_HOST=0.0.0.0`, open UFW for Docker bridge
- Applied fixes to `pkg/open-webui/init.sh`: replaced `ENABLE_PERSISTENT_CONFIG=False` with `ENABLE_OLLAMA_API=False`
- Updated test fixture with `API_SERVER_HOST=0.0.0.0`, added tests for host value and Docker-to-hermes connectivity
- **Second blocker found**: UFW active with INPUT DROP policy blocks Docker bridge (172.17.0.1) even after hermes binds 0.0.0.0. Ubuntu 24.04 cloud image ships UFW enabled — not a cloudify package. Added UFW rule in hermes-openwebui init.sh
- 13/13 tests passing after all fixes
- End-to-end verified: openwebui -> hermes -> keylessai -> response. User confirmed "hello" -> "How can I help you"
- Also: added token efficiency + history sections to CLAUDE.md, fixed CLAUDE.md git remote docs (origin=GitHub, push with `git push`)
- Files changed: `CLAUDE.md`, `HISTORY.md` (new), `pkg/hermes-openwebui/init.sh`, `pkg/open-webui/init.sh`, `tests/integration/package-hermes-openwebui.bats`

## 2026-05-13 — Hardened hermes-openwebui for production use

- hermes-openwebui: gateway now installed as systemd user service (`hermes gateway install` + linger) instead of nohup
- open-webui: added `CLOUDIFY_OPENWEBUI_BIND` config (default `127.0.0.1`, set `0.0.0.0` for Tailscale access)
- open-webui: added `ENABLE_WEBSOCKET_SUPPORT=true` for mobile clients (Conduit)
- Test updated to use systemd service instead of nohup
- 13/13 tests passing, gateway confirmed running as systemd service with linger=yes
- Documented Docker-to-host networking in pkg READMEs
- Files: `pkg/hermes-openwebui/init.sh`, `pkg/open-webui/init.sh`, `tests/integration/package-hermes-openwebui.bats`, `pkg/hermes/README.md` (new), `pkg/hermes-openwebui/README.md`, `pkg/open-webui/README.md`

## 2026-06-05: lazygit — distro-version aware install

- Made lazygit recipe distro-version aware: uses `pkg_apt_install` on Debian 13+/Ubuntu 25.10+ where lazygit is in apt, falls back to GitHub release download for older distros
- Added idempotency guard (`command -v lazygit`) and `pkg_depends curl` for the GitHub path
- Kept existing `pkg_in_startuprc "alias lg=lazygit"`
- 3/3 integration tests passing on Ubuntu 24.04 container (GitHub release path)
- Files: `pkg/lazygit/init.sh`

## 2026-06-05: yazi — new package (terminal file manager)

- New package: `pkg/yazi/init.sh` — installs via `pkg_install_release` which picks the official `.deb` from GitHub releases
- Depends on `file` (prerequisite per yazi docs)
- Adds `alias y=yazi` to .bashrc
- Verified working on Ubuntu 22.04 (local install)
- Bug: glibc .deb requires 2.39+ — Ubuntu 22.04 has 2.35 → switched to musl .deb on older distros
- Bug: arch conversion x86_64→amd64 broke URL — yazi uses x86_64/aarch64 in filenames → use uname -m as-is
- Integration test written but not yet run (incus remote unreachable)
- Files: `pkg/yazi/init.sh`, `tests/integration/package-yazi.bats`

## 2026-06-11: hermes-dashboard — persistent web dashboard via systemd + tailscale serve

- New package: `pkg/hermes-dashboard/` — runs hermes dashboard as a systemd user service
- Includes `relay.py` — aiohttp reverse proxy that rewrites Host header for tailscale serve compatibility (workaround for missing --allowed-hosts, hermes-agent#34390)
- Exposed via `ivps expose-direct cloudai:hermes 9120 --path /dashboard` → https://hermes.komodo-everest.ts.net/dashboard
- Added PATH to systemd unit (node/npm at ~/.local/bin needed for web UI build)
- Added dashboard readiness check in relay (waits up to 30s for first-launch web UI build)
- Verified: systemd service active, relay HTTP 200, tailscale HTTPS 200
- Roadblock: path-based routing (`--path /dashboard`) breaks SPA — JS bundles use absolute `/api/*`, `/fonts/*` paths
- Root exposure works (`https://hermes.komodo-everest.ts.net/`) but collides with Open WebUI on same container
- Solution: ivps needs `expose-private-hostname` command for hostname-based tailnet routing
- See `/home/rbc/.pi/handoffs/2026-06-11-ivps-expose-private-hostname.md`
- Files: `pkg/hermes-dashboard/init.sh`, `pkg/hermes-dashboard/relay.py`, `tests/integration/package-hermes-dashboard.bats`

## 2026-06-11 — expose-private-hostname rejected; separate containers chosen

- Investigated ivps `expose-private-hostname` for tailnet hostname routing via Caddy on gateway.
  Found fatal TLS flaw: Tailscale CA doesn't issue subdomain certs (`dashboard.hermes.ts.net`).
  Issue [#7081](https://github.com/tailscale/tailscale/issues/7081) still open.
- Evaluated alternatives: Tailscale Services (requires tagged identity + admin console setup),
  DNS-01 + Let's Encrypt (requires Caddy rebuild), separate containers.
- **Decision: separate containers.** Hermes dashboard stays on hermes container at root
  (`tailscale serve --bg 9119`). Open WebUI moves to its own container with its own
  MagicDNS hostname. Each gets root HTTPS + auto-TLS with zero infra changes.
- See `/home/rbc/.pi/handoffs/2026-06-11-cloudify-separate-containers.md`

## 2026-06-11 — Architecture refined: SSH tunnel for dashboard, MagicDNS for API

- Common-sense tested all assumptions from previous handoff via exa research.
  Confirmed: subdomain certs dead (#7081), SPA path routing broken (#12413),
  Tailscale Services require tags+approval, caddy-tailscale only issues certs
  for local machine.
- Key correction: hyphens in machine names (`openwebui-hermes`) are NOT subdomains.
  Tailscale MagicDNS and CA treat hyphenated names as first-class machine identities.
  `openwebui-hermes.komodo-everest.ts.net` gets a valid cert.
- Rejected Caddy as central reverse proxy: one Caddy on cloudai can't serve
  multiple MagicDNS hostnames because caddy-tailscale only gets certs for its
  own machine's FQDN. Central Caddy only works with path-based routing → SPAs break.
- **Final architecture:**
  - `hermes` container: tailscale serve (:443 → agent :8642), dashboard loopback-only via SSH tunnel (`ssh -L 9119:127.0.0.1:9119 hermes`). No relay.py. No dashboard tailscale serve.
  - `openwebui-hermes` container: tailscale serve (:443 → Docker :3000), Docker DNS 100.100.100.100 for MagicDNS, `OPENAI_API_BASE_URL=https://hermes.komodo-everest.ts.net/v1`
  - No Caddy. No hardcoded Tailscale IPs. No path-based routing anywhere.
- Cloudify changes:
  1. `hermes-dashboard/init.sh` — simplify: direct dashboard (:9119 loopback), remove relay.py, post-install shows SSH tunnel command
  2. `open-webui/init.sh` — add `dns: 100.100.100.100` to docker-compose, support remote hermes URL from credentials
  3. `hermes-openwebui/init.sh` — remove same-machine assumptions, support remote hermes via MagicDNS
  4. New `hermes-openwebui/connect-remote.sh` — wire open-webui to hermes across Tailscale
  5. Tests for all of the above

## 2026-06-11 — separate-containers v2: deployment in progress

- **Merged PR #1**: hermes-dashboard (no relay, SSH tunnel), open-webui (MagicDNS dns), hermes-openwebui (remote via MagicDNS). 9 files changed, +362/-439.
- **Merged** 388e79d: remote.sh now passes CLOUDIFY_HERMES_API_URL and CLOUDIFY_HERMES_API_KEY through remote payload
- **hermes container** (cloudai:hermes): stopped open-webui Docker, removed relay.py, dashboard running standalone on 127.0.0.1:9119 (ssh -L tunnel), tailscale serve reconfigured to serve API at root `/` → 8642. Gateway + Slack still running.
- **TS_AUTH_KEY** was expired (one-off key from April). User generated new reusable key with tag:incus. Required ACL rule `tag:incus → tag:incus:443` added.
- **openwebui-hermes container** (cloudai:): created via `ivps launch`, Tailscale connected with tag:incus, MagicDNS resolving hermes hostname. SSH set up. Credentials configured.
- **open-webui installed** via cloudify. Docker container starts but crashes with `ValueError: No embedding model is loaded`. Patched compose with `RAG_EMBEDDING_ENGINE=` to disable embeddings. Still not healthy — container keeps restarting.
- **Roadblock**: open-webui won't stay up. Needs debugging — may need different RAG_EMBEDDING_ENGINE value or additional env vars.
- **Untested**: hermes-openwebui package install (credentials passthrough fixed but open-webui must be healthy first), tailscale serve on openwebui-hermes, end-to-end TLS verification.
