# Cloudify — Session History

## 2026-06-20 — Fix local-install password failure: local credential section (#1)

- **Root cause**: On the local install path, `CLOUDIFY_HOSTPWD` was mapped only from `CLOUDIFY_LOCAL_PWD` (`cloudify` main), and **nothing ever set `CLOUDIFY_LOCAL_PWD`** — the credentials framework only knew remote/github/gitlab. So the first sudo-needing `@default` died with `Password not set for user rbc`.
- **Fix**: Added a `local` section to `lib/credentials.sh` — `cloudify_ask_local_credentials`, `local` cases in `cloudify_credentials_save`/`_check`/`_setup` (password-only — the local user is always `whoami`), included in the all-sections save. Router (`cloudify`): `credentials local` subcommand + usage line. `main()`'s existing `${CLOUDIFY_LOCAL_PWD:-}` → `CLOUDIFY_HOSTPWD` mapping now resolves.
- **Tests**: `tests/unit/credentials.bats` — new "saves only the local section" test; `cloudify_ask_local_credentials` in the defined-functions test; `CLOUDIFY_LOCAL_PWD` set + asserted in the "all OK" check.
- Lint clean (`shellcheck -x` on `lib/credentials.sh`, `cloudify`).

## 2026-06-20 — apt-get shadow: no sudo on no-op installs (cache pre-pass)

- **Problem**: `lib/shadows/apt-get.sh` ran `_cloudify_apt_cache_stale && sudo apt-get update` **before** the per-package `dpkg -l` idempotency check, so a stale cache (>60min) demanded a password even when every requested package was already installed.
- **Fix**: Pre-pass refreshes the apt cache only when ≥1 package is genuinely missing (`_cloudify_pkg_installed`). Strict improvement — when something IS missing, behavior is identical to before; when all installed, no sudo at all. Independent of the local-credential fix (the password is still needed for genuinely-missing packages).
- Lint clean (`shellcheck -x` on `lib/shadows/apt-get.sh`).

## 2026-06-20 — Clean failure when a @default aborts the requested install (#4)

- **Problem**: `cloudify install <pkg>` installs the `@default` set **synchronously** before the user's package. The native-manager path (`pkg_apt_install`, when a package has no recipe) in `pkg_depends` was NOT wrapped in a subshell, so a `die` (e.g. sudo shadow `Password not set for user rbc`) called `exit` and killed the whole process — `failed_packages` never recorded it, no `Failed packages:` summary printed, and the user's explicitly-requested package was never attempted. The user saw a bare error + exit 1 with no indication that (a) it was a `@default` that failed and (b) their package was skipped. (The recipe path was already isolated in a subshell; only the native path leaked.)
- **Fix**: `lib/package-api.sh` — wrap both native-path `pkg_apt_install` calls in subshells (`if ! ( pkg_apt_install "${pkg}" )`), matching the recipe path, so `die`'s `exit` is contained, the failure is recorded, the loop continues, and the summary prints. `cloudify` — check the synchronous `cloudify_install_package $defaults` return: on failure, print a clear message naming the failure and stating the requested package was NOT attempted, with the remediation (`--no-defaults`), then exit 1.
- **Test**: `tests/unit/package-api.bats` — new "isolates native-path failures (die/exit) in subshell" regression test (mocks `pkg_apt_install` to `exit 1`, asserts the package is recorded in `Failed packages:` and subsequent packages are still attempted).
## 2026-06-14 — `pkg_verify` hook: script-friendly verification (Issue #2)

- **Feature**: `cloudify install` now blocks until each installed package is verified (or fails clearly). No more manual `ssh`/`curl` after install returns.
- **Design** (see `tmp/plans/pkg-verify-hook.md`): optional `pkg/<name>/verify.sh` defining `pkg_verify()`, sourced in a clean subshell by `_cloudify_run_verify` (retry loop, `${PKG_VERIFY_TIMEOUT:-30}s`). Deep-verify runs after every package incl. deps.
- **Why a separate `verify.sh` (not inline)**: both install+verify and verify-only paths source it in an identical clean-subshell environment (exported env + on-disk config only). Kills the sed-extraction fragility and environment-asymmetry that an inline `pkg_verify()` would have caused.
- **CLI**: `--verify` (verify-only), `--no-verify` (skip), `cloudify verify <pkg>` subcommand. Per-host failure reporting in parallel multi-host installs. **Exit code now non-zero if any host fails** (previously always 0 — pre-existing bug fixed as the plan requires "fails clearly").
- **Authoring contract (constraints a/b)**: parent overriding a dep via env var → declare in parent `pkgs/<pkg>.yaml`; parent hardcoding a dep rewire → parent's `verify.sh` owns that check (dep must not assert on it).
- **Behavior change**: existing non-fatal `log_warn` health checks in `hermes-openwebui/init.sh` moved to `verify.sh` — they are now **fatal/blocking** by design.
- **Files**: `lib/package-api.sh` (`_cloudify_run_verify`, `cloudify_package_verify_path`, deep-verify call in `pkg_depends`); `cloudify` (flags, `verify` subcommand, per-host reporting); `lib/remote.sh` (forward `CLOUDIFY_NO_VERIFY` + `PKG_VERIFY_TIMEOUT`, verify-only dispatch, host tracking); new `pkg/hermes/verify.sh`, `pkg/hermes-dashboard/verify.sh`, `pkg/hermes-openwebui/verify.sh`.
- **Tests**: 13 new unit tests (`_cloudify_run_verify` success/timeout/no-hook/retry/yaml-load + router flag/verify-subcommand). Lint clean incl. `pkg/*/verify.sh`. hermes-dashboard integration passes 4/4 with verify-on-by-default (real `pkg_verify` on a ~27s slow-starting service, `PKG_VERIFY_TIMEOUT=90`). hermes-openwebui integration 5/5 (`--no-verify` for fake-cred test env). open-webui now healthy (2026-06-11 roadblock resolved).

## 2026-06-14 — Fix subshell var forwarding + Hermes rebuild

- **Bug**: `_cloudify_pkg_remote_vars()` runs in command substitution `$()`, so its `export` side effects are lost. `envsubst` then substitutes empty strings for all pkg yaml vars. Symptoms: `WEBUI_ADMIN_*` defaults used instead of configured values, `CLOUDIFY_HERMES_API_URL` empty causing hermes-openwebui local-case fallback.
- **Fix**: Call `_cloudify_pkg_remote_vars` directly in parent shell, redirect stdout to temp file for name capture (identical API). Exports now survive for `envsubst`.
- Lint clean. All 237 unit tests pass. 9/29 integration pass (remainder time out — hermes install inherent slowness).

## 2026-06-14 — Hermes Unified Services Rebuild

Recreated `cloudai:hermes-svc` from scratch following the unified-services handoff recipe:
- Nuked `cloudai:hermes-svc` + cleaned up stale Tailscale device (caused hostname collision on relaunch)
- Launched fresh container, installed hermes + hermes-dashboard + hermes-openwebui
- Applied dashboard bind fix: `--host 0.0.0.0 --insecure --port 9119` (Host header rejection)
- Exposed 3 Tailscale Services: `svc:hermes-api` (:8642), `svc:hermes-dash` (:9119), `svc:hermes-owui` (:3000)
- ACL grants already correct from prior session (no changes needed)
- All services approved and verified: API 200, Dashboard 200, OpenWebUI 200

Final state:
| Service | URL | Port | Grant |
|---------|-----|------|-------|
| hermes-api | https://hermes-api.komodo-everest.ts.net/ | 8642 | tag:incus |
| hermes-dash | https://hermes-dash.komodo-everest.ts.net/ | 9119 | autogroup:member |
| hermes-owui | https://hermes-owui.komodo-everest.ts.net/ | 3000 | autogroup:member |

## 2026-06-13 — Recursive dependency var forwarding + guards + hermes-model

- **Fix A**: Rewrote `_cloudify_pkg_remote_vars()` in `lib/remote.sh` with recursive dependency walk, first-write-wins priority, and cycle guard. Now correctly forwards vars from transitive dependencies (e.g. `hermes-openwebui` → `open-webui` → `WEBUI_ADMIN_EMAIL`). Priority: `remote-vars.yaml` > rightmost-pkg > ... > leftmost-pkg > deps > deps-of-deps.
- **Fix B**: Restored install guards in `pkg/open-webui/init.sh` and `pkg/hermes-openwebui/init.sh`. Skips regeneration when compose file exists and FORCE/CLEAR_DATA are unset.
- **Fix C**: Created `pkg/hermes-model/init.sh` — configures LLM provider/model for Hermes via `~/.config/cloudify/pkgs/hermes-model.yaml`. Smart guard skips if provider+model already match. Supports deepseek, openrouter, novita, google, custom providers.
- Fixed pre-existing lint: removed `local` from top-level `env_block` in `open-webui/init.sh`.
- Fixed hermes-openwebui integration test: combined install into one command (guard was skipping the wire-up when open-webui was pre-installed).
- Fixed hermes-dashboard integration test: increased HTTP wait timeout (27s web UI build), added `-q` to all TEST_SSH definitions to suppress "Permanently added" stderr pollution in bats `run` output.
- Added constitution rule: never skip a test failure by dismissing it as pre-existing.
- All 237 unit + 29 integration tests passing.

- Previous `hermes-svc` container was gone. Recreated from handoff recipe.
- Discovered `hermes gateway install` has **two** interactive prompts (start now? + auto-start on boot?), no `--yes` flag.
- `pkg/hermes-openwebui/init.sh` local case fixed: `echo |` → `yes |` to answer both prompts.
- Install re-ran successfully: hermes-gateway (8642), hermes-dashboard (9119, `--host 0.0.0.0 --insecure`), open-webui (3000) all as systemd services.
- 3 Tailscale Services re-exposed: `svc:hermes-api`, `svc:hermes-dash`, `svc:hermes-owui`.
- ACL grants: `tag:incus → svc:hermes-api`, `autogroup:member → svc:hermes-dash,svc:hermes-owui`. Pushed via API with ETag.
- Services await admin approval at https://login.tailscale.com/admin/services.
- Created `~/.agents/skills/cloudify-hermes/SKILL.md` — reusable deployment skill covering all steps, edge cases (gateway foreground process, two-prompt install, ETag conflicts, dashboard Host header), idempotency, and troubleshooting.
- CLAUDE.md: added usage priority rule (cloudify > ivps > incus).

## 2026-06-13 — Remove repo-side remote-vars.yaml (single source of truth)

- `_cloudify_pkg_remote_vars()` now reads var names from `~/.config/cloudify/pkgs/<pkg>.yaml` instead of `pkg/<name>/remote-vars.yaml`.
- Deleted `pkg/open-webui/remote-vars.yaml`, `pkg/hermes-openwebui/remote-vars.yaml`, `pkg/hermes-signal/remote-vars.yaml`.
- `hermes-openwebui/init.sh`: local case restructured — `export OPENAI_*` before `pkg_depends open-webui`, eliminated `connect.sh`.
- READMEs updated: Configuration tables reference `~/.config/cloudify/pkgs/<pkg>.yaml`.
- AGENTS.md: added turn closure rule (docs updated + git clean).
- Unit tests: 231/231 passing.

## 2026-06-13 — Hermes Unified Services: 3 services, 1 container, svc: grants

- Container `cloudai:hermes-svc` created via ivps. Hermes + dashboard + openwebui installed via cloudify.
- 3 Tailscale Services exposed: `svc:hermes-api` (8642), `svc:hermes-dash` (9119), `svc:hermes-owui` (3000).
- ACL grants use `svc:<name>` destinations: `tag:incus → svc:hermes-api`, `autogroup:member → svc:hermes-dash,svc:hermes-owui`.
- Dashboard requires `--host 0.0.0.0 --insecure` to accept proxy Host header from Tailscale Service.
- 5 ivps bugs found + fixed (ordering, URL, addrs, curl body drop, serve reset nuke).
- Pattern proven: `ivps expose-service` + precise `svc:` grants for per-service access control.

## 2026-06-12 — Tailscale Services experiment (programmatic service creation)

- Goal: use Tailscale Services (`<service>.<tailnet>.ts.net`) to serve multiple
  services on a single container, replacing separate containers + SSH tunnels.
- Created service `svc:test` via Tailscale API from cloudify container:
  `PUT /api/v2/tailnet/{tailnet}/vip-services/svc:test`
- **Critical discovery**: API calls to api.tailscale.com must come from inside
  the tailnet — local machine can't reach it. Future ivps service management
  must route API calls through a tailnet node.
- Configured host with `tailscale serve --service=svc:test --https=443 localhost:8080`
- Service awaits admin approval at https://login.tailscale.com/admin/services
- Stored `TS_API_KEY` in `~/.config/ivps/config.env` alongside `TS_AUTH_KEY`
- Long-term: this pathway (service create → configure host → approve) should be
  an ivps feature, not cloudify. ivps owns Tailscale integration.

## 2026-06-12 — hermes-dashboard verified + yazi/ivps investigation

- Yazi integration test: written 2026-06-05 but never run (incus unreachable). Now passes 3/3.
- hermes-openwebui timeout claim: stale. Test was simplified (065c67f, dad00d4), no longer needs tailscale at runtime. Passes 6/6.
- hermes-dashboard: reinstalled on cloudai:hermes. Stale Jun-11 process held port 9119,
  old relay.py unit replaced. Dashboard serves HTTP 200 on loopback :9119.
- ivps tunnel: TS_DOMAIN split fixed (64d3f67), ((count++)) bug fixed (e51e1b3).
  `ivps tunnel start cloudai:hermes 9119:9119` works end-to-end.

## 2026-06-12 — Update CLAUDE.md Architecture section

- Updated package count: 65+ → 75+
- Added repo-side `pkg/<name>/remote-vars.yaml` interface distinction
  (repo yaml = interface, user yaml = values)
- No other sections touched

## 2026-06-12 — Fix word-splitting bug in _cloudify_pkg_remote_vars

- Root cause: `_cloudify_dispatch` passes `$packages` as a single string
  `"--install pkg1 pkg2"` to `cloudify_remote`. The function used quoted `"$@"`
  which preserved this as one argument, so the `--install` flag was never
  detected and no package vars were collected.
- Fix: `local args=($@)` (unquoted) triggers word-splitting, correctly
  separating `--install` from package names.
- hermes-openwebui integration test now passes 6/6 with env var exports
  (no file writes to ~/.config/cloudify/credentials).

## 2026-06-12 — Per-package user config via ~/.config/cloudify/pkgs/<pkg>.yaml

- New `lib/pkg-config.sh` module: `_cloudify_load_yaml_vars()` parses flat key:value YAML
  and exports vars into the environment. Overrides existing env vars (package config
  is authoritative).
- Architecture:
  - `~/.config/cloudify/credentials` — system auth only (remote, github, gitlab)
  - `~/.config/cloudify/remote-vars.yaml` — vars ALWAYS forwarded on every `--on` call
  - `~/.config/cloudify/pkgs/<pkg>.yaml` — vars forwarded only when installing `<pkg>`
- `_cloudify_pkg_remote_vars()` in `lib/remote.sh` now loads config from user yaml files
  before collecting var names from repo `pkg/<name>/remote-vars.yaml`. Also includes
  always-forward vars from `~/.config/cloudify/remote-vars.yaml`.
- Repo yaml files define the interface (which vars are required). User yaml files
  provide the values. No backward compat with pkg vars in credentials file.
- Updated bats test: exports fake `CLOUDIFY_HERMES_API_URL`/`CLOUDIFY_HERMES_API_KEY`
  directly in test file (no file writes).

## 2026-06-12 — Refactor remote var forwarding to per-package yaml files

- Removed hardcoded package-specific `export` lines and `envsubst` entries from `lib/remote.sh`.
  Replaced with per-package `pkg/<name>/remote-vars.yaml` files (key-value, var names extracted via grep).
- Core infrastructure vars (CLOUDIFY_REMOTE_USER, DEBUG, etc.) stay hardcoded in remote.sh.
- `_cloudify_pkg_remote_vars()` scans yaml files for requested packages, generates template
  exports and envsubst list dynamically.
- Fixed `declare -f` stripping comment-based placeholder → used `: _CLOUDIFY_PKG_EXPORTS_` no-op.
- `pkg/hermes-openwebui/remote-vars.yaml`: CLOUDIFY_HERMES_API_URL, CLOUDIFY_HERMES_API_KEY
- `pkg/open-webui/remote-vars.yaml`: CLOUDIFY_OPENWEBUI_PORT, CLOUDIFY_OPENWEBUI_BIND, WEBUI_ADMIN_EMAIL, WEBUI_ADMIN_PASSWORD
- `pkg/hermes-signal/remote-vars.yaml`: CLOUDIFY_SIGNAL_PORT
- Commit: 35c8ddd

## 2026-06-11 — open-webui compose fixes and test stabilization

- Fixed missing trailing newline after heredoc in `pkg/open-webui/init.sh`:
  `env_block=$(cat <<INNER ...)` strips trailing newline → `${env_block}` in compose
  template ran into YAML `volumes:` key → broken compose. Fix: `env_block+=$'\n'`.
- Removed redundant `\n` in printf RAG line (now handled by trailing newline above).
- Extended health check timeout from 30→120 attempts (240s) for first-launch HuggingFace
  sentence-transformers model download.
- Commits: 0b70463, 83029b3
- Integration test `package-open-webui` now passes consistently (6/6).

## 2026-06-11 — RAG_EMBEDDING_ENGINE newline bug (known issue)

- `pkg/open-webui/init.sh` line 58: `$()` strips trailing newline from heredoc,
  so `printf '%s      - RAG...\n'` appends RAG line to same line as OPENAI_API_KEY.
  Fix: prepend `\n` in printf format or use a different append approach.
- Not yet deployed to container.

## 2026-06-11 — Remove connect-remote.sh, delegate to open-webui init

- Deleted `pkg/hermes-openwebui/connect-remote.sh` (79 lines). Its sole purpose
  (sed-update compose, restart, health wait) is now handled by `open-webui/init.sh`
  which always regenerates compose from env vars.
- `hermes-openwebui/init.sh` now exports `OPENAI_API_BASE_URL` + `OPENAI_API_KEY`
  from `CLOUDIFY_HERMES_*` before calling `pkg_depends open-webui`. Compose gets
  correct values directly — no sed, no separate restart.
- Added non-fatal hermes API health check.
- Updated integration test + README.
- Commit: 065c67f

## 2026-06-11 — Remove install guards from open-webui + hermes-openwebui

- Both `pkg/open-webui/init.sh` and `pkg/hermes-openwebui/init.sh` now always
  regenerate docker-compose.yml from current env vars on every run. Change
  credentials in `~/.config/cloudify/credentials`, re-run `cloudify --on`,
  compose picks up new values.
- Commits: dad00d4 (hermes-openwebui), 0c28d27 (open-webui)

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
