# Cloudify — Session History

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
