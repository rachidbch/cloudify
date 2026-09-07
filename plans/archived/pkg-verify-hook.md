# Plan: `pkg_verify` Hook — Script-Friendly Verification

> Issue: [#2](https://github.com/rachidbch/cloudify/issues/2)

## Goal

Every `cloudify install` either blocks until the work is verified done, or fails clearly.
No more manual `ssh`/`curl` after `cloudify` returns.

## Design

### CLI Surface

```
cloudify --on <host> install <pkg>               install + verify (default)
cloudify --no-verify --on <host> install <pkg>   install, skip verify
cloudify --verify --on <host> install <pkg>      verify only, no install
cloudify verify <pkg>                            verify only (local / remote dispatch)
```

`--verify` / `--no-verify` are global flags, parsed before `--on`.
Default (neither flag): install + verify.
If a package has no `verify.sh`, verification is a no-op (no error, no delay).

### Verification File: `pkg/<name>/verify.sh`

Optional recipe file. Defines `pkg_verify()`.

- **Sourced, not extracted.** Both invocation paths `source verify.sh` in a clean
  subshell — identical environment by construction. No sed, no eval. `pkg_verify`
  may use any bash construct (nested braces, heredocs, local helpers).
- **Clean subshell environment.** The subshell carries exported env + on-disk state
  only — NOT the recipe's local shell vars. So `verify.sh` reads inputs from env
  vars (yaml) or config files the recipe wrote, never from recipe-local variables
  and never from hardcoded `host:port` literals.
- **Optional.** No `verify.sh` → `_cloudify_run_verify` returns 0 immediately.

```bash
# pkg/hermes-dashboard/verify.sh
pkg_verify() {
    local port="${HERMES_DASHBOARD_PORT:-9119}"
    systemctl --user is-active hermes-dashboard >/dev/null 2>&1 || return 1
    curl -sf --max-time 5 "http://127.0.0.1:${port}" >/dev/null || return 1
}
```

### Infrastructure: `_cloudify_run_verify` (lib/package-api.sh)

- Resolve `verify.sh` via `$(dirname $(cloudify_package_recipe_path "$pkg"))/verify.sh`.
- If absent → return 0.
- Load `pkgs/<pkg>.yaml` (localhost needs this; remote already has vars forwarded).
- Retry loop: `source verify.sh; pkg_verify` in a subshell, errexit-safe via `if`-check (F1).
- Sleep 2s between attempts. Timeout: `${PKG_VERIFY_TIMEOUT:-30}`.
- On success → log elapsed. On timeout → log error + last output, return 1.

### Deep Verify (A2)

Called from `pkg_depends` after **every** package's recipe (deps included):

```bash
# after successful recipe source + script install:
if [[ "${CLOUDIFY_NO_VERIFY:-}" != "true" ]]; then
    _cloudify_run_verify "$pkg" || { failed_packages+=("$pkg"); continue; }
fi
```

Continue-on-failure (A1) — no loop control change vs current code.

**Authoring contract (constraints a + b):**
- (a) Parent overrides dep behavior via env var → declare in parent's
  `pkgs/<pkg>.yaml` (forwarded parent-priority via `_cloudify_pkg_remote_vars`)
  → dep's `verify.sh` reads it. Parent must NOT set it imperatively in the recipe
  body (that runs after the dep is already verified).
- (b) Parent hardcodes a rewire of a dep → parent's `verify.sh` asserts the rewired
  behavior; dep's `verify.sh` must NOT assert on it. (Why base `hermes` has no
  `verify.sh`; `hermes-openwebui` owns the API-connection check.)

### Verify-Only Dispatch

`--verify` flag sets `CLOUDIFY_VERIFY_ONLY=true`. In `_cloudify_dispatch`:
- localhost: call `_cloudify_run_verify` per pkg (skip install).
- remote: send `cloudify verify <pkgs>` instead of `cloudify install <pkgs>`.

`verify` subcommand (`cloudify verify <pkg>`): init paths, run `_cloudify_run_verify`
per pkg. Used directly and as the remote-dispatch target.

### Parallelism & Per-Host Failure Reporting

Multi-host: backgrounded SSH. Track `_CLOUDIFY_BG_HOSTS[$pid]=$host` in both
`cloudify_remote` (remote) and `_cloudify_execute_package_action` (localhost).
Reset `$CLOUDIFY_TMP/${host}.exit` at dispatch start. After `wait`, read exit files:

```
host1: OK
host2: hermes-dashboard verification failed (timeout after 30s)
host3: OK
---
1/3 hosts failed.
```

Exit code: non-zero if any host failed.

### Files Changed

| File | Change |
|------|--------|
| `lib/package-api.sh` | Add `_cloudify_run_verify`. Call in `pkg_depends` after each pkg (deep verify, continue-on-failure, gated by `CLOUDIFY_NO_VERIFY`). |
| `cloudify` | Parse `--verify`/`--no-verify` (before `--on`). Add `verify` subcommand. Update `usage()`. `_CLOUDIFY_BG_HOSTS[]` tracking + per-host report. Reset `.exit` files at dispatch. |
| `lib/remote.sh` | Forward `CLOUDIFY_NO_VERIFY` + `CLOUDIFY_VERIFY_ONLY` in payload template + envsubst allow-list. Verify-only dispatch sends `cloudify verify`. Track host in `cloudify_remote`. |
| `pkg/hermes/verify.sh` | NEW — `pkg_verify`: `command -v hermes`. |
| `pkg/hermes-dashboard/verify.sh` | NEW — `pkg_verify`: `systemctl --user is-active` + `curl http://127.0.0.1:${HERMES_DASHBOARD_PORT:-9119}`. |
| `pkg/hermes-openwebui/verify.sh` | NEW — branch-aware. Always: `curl http://127.0.0.1:${CLOUDIFY_OPENWEBUI_PORT:-3000}/health`. Remote mode: `curl ${CLOUDIFY_HERMES_API_URL%/}/health`. Local mode: read `API_SERVER_PORT` from `~/.hermes/.env`, `curl http://127.0.0.1:${port}/health`. |
| `pkg/hermes-openwebui/init.sh` | Remove `log_warn` health checks (moved to verify.sh; now fatal/blocking — behavior change, HISTORY note). |
| `tests/unit/package-api.bats` | `_cloudify_run_verify`: success, timeout, no-verify.sh, retry-then-success, `CLOUDIFY_NO_VERIFY` skip. |
| `tests/unit/shell-router.bats` | `--verify`/`--no-verify` parsing; `verify` subcommand. |
| `tests/integration/` | `--no-verify` skip; `verify`-only; update hermes tests for verify.sh. |
| `README.md` | Recipe-author section: `verify.sh` convention, clean-subshell env rule, env-var/config-driven endpoint rule, constraints (a)/(b). |
| `pkg/hermes*/README.md`, `AGENTS.md`, `HISTORY.md`, `ROADMAP.md` | Document feature + decisions; roadmap: abort-on-failure review (A1), hermes-owns-gateway (Q1). |

### Hard Rules (recipe authors)

1. `verify.sh` is a separate optional file in `pkg/<name>/`, defining `pkg_verify()`.
2. `verify.sh` runs in a clean subshell: exported env + on-disk config only. Read
   inputs from env vars (yaml) or config files — never recipe-local vars, never
   hardcoded `host:port`.
3. Any bash construct allowed (no sed/eval limitation — it is sourced).
4. Idempotent — called repeatedly by the retry loop.

### Decisions Log

| ID | Decision |
|----|----------|
| B1 | No hardcoded endpoints — env vars or config-file reads. Same-container vs separate-container handled by which env var is populated. |
| G1 | Forward `CLOUDIFY_NO_VERIFY`/`CLOUDIFY_VERIFY_ONLY` through remote payload + envsubst allow-list. |
| G2 | TDD: unit + integration tests. |
| G3 | All docs updated (README, pkg READMEs, AGENTS, HISTORY, ROADMAP). |
| G4 | `verify.sh` separate file — sourced post-install in clean subshell. |
| G5 | Withdrawn — optional hook is additive. Existing `log_warn` checks → verify.sh (now fatal/blocking). |
| F1 | `_cloudify_run_verify` errexit-safe via `if`-check. |
| F2 | Dropped — sed limitation gone (verify.sh sourced, not extracted). |
| F3 | Solved — both paths source verify.sh in identical clean-subshell environment. |
| A1 | Continue-on-failure (current code). Roadmap: review abort policy. |
| A2 | Deep verify (deps too). Constraints (a)+(b) govern authoring. |
| M1 | Track hosts in `cloudify_remote` + `_cloudify_execute_package_action`. |
| M2 | Reset `.exit` files at dispatch start. |
| M3 | localhost loads `pkgs/<pkg>.yaml` in `_cloudify_run_verify`. |
| M4 | `usage()` updated. |

### Implementation Process

1. **Feature branch**: `git checkout -b feat/pkg-verify`
2. TDD: write tests first, implement, `task lint && task test-unit && task test`
3. Push: `git push -u origin feat/pkg-verify`
4. **DO NOT merge to master.** Wait for explicit go-ahead.
5. After merge from master, run the hermes rebuild recipe with the new UX.

## ivps Issues (separate project)

| Issue | Detail |
|-------|--------|
| `ivps launch` should block until SSH-ready | Add `--no-wait` / `--wait` flags |
| `ivps delete` should block until container gone | Add `--no-wait` / `--wait` flags |

To file in `/home/rbc/PROJECTS/PROD/ivps/` project.
