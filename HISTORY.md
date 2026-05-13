# Cloudify — Session History

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
