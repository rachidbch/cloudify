---
name: cloudify-dev
description: Use when developing, upgrading or debugging the cloudify tool itself. For using cloudify see cloudify; for packages see cloudify-pkg-dev.
---

# Developing cloudify

## Constitution

- The bats harness is the completion gate, never the debugger. Prove the change with static checks and a manual run on the target, then run the harness once, at the end. Debugging through a full harness run multiplies the cost of every change.

## DONOT

- Never convert `curl URL | bash -s -- args` into `bash -c "$(curl URL)" ...`. With `bash -c` the next word becomes `$0`: the script receives `--` as its first argument. Download to a file, run `bash <file> <args>`.
- Never dispatch without `CLOUDIFY_FORCE_UPDATE=true` while iterating. The 30-minute gate silently runs stale code; the only trace is the `checkout v1:` line.
- Never redirect or filter cloudify output (`>/dev/null`, pipes, `rg` on first read), never trust memory over the log. Transcripts are evidence: `/tmp/cloudify/logs/<ts>.log` on the controller, `latest.log` only on hosts (AGENTS.md LOGS).
- Never rerun with a timeout below the last observed duration. After any self-inflicted timeout kill, the next timeout is 3x observed.
- Never inline quotes, pipes or `$()` in `cloudify exec '<cmd>'` - the channel mangles them. Push a script (`ivps push`) and run the file.
- Never `cloudify app run` on a dirty tree - commit the plan first.

## Layout

- `cloudify`: router only (arg parsing + dispatch). All logic in `lib/*.sh`, each with a `_CLOUDIFY_X_LOADED` guard, sourced by the router.
- `lib/package-api.sh`: `pkg_*` API used by recipes. Signatures are stable.
- `lib/shadows/*.sh`: overrides for `sudo`, `apt-get`, `add-apt-repository`, `git` (password injection, idempotency, auth).
- `lib/vars.sh`: five-source var helpers + precedence walker + secret resolver.
- `lib/remote.sh`: payload build + ssh transport (stdin).
- `lib/targets.sh`: `--on` target grammar (`X`/`X:`/`X:Y`/`:Y`) -> (node, instance, ssh host); ivps is the inventory provider.
- `lib/registry.sh`: observation records per (deployment, target, package) under the ivps node dir; written after a dispatch, swept by `deployment delete`.
- `lib/runbooks.sh`: runbook parse/bind/preflight/run/replay + run snapshots.
- `pkg/<name>/`: recipes. `tests/`: bats. `plans/`, `ADR.md`, `HISTORY.md`, `LOGS.md`.

## Critical gate

Any change to `lib/` or the router runs the CRITICAL GATE (project AGENTS.md):
description artifact -> plan + non-breakage argument -> explicit human consent.
Record it in `plans/`. The brittle core is the remote payload (envsubst allow-list, single-quote baking, stdin transport) and the shadow functions; describe before changing.

## Invariants

- Collector exports are the value channel: invoke readers with a redirect, never `$(...)`.
- Payload travels on stdin, never argv. Never `exec </dev/null` globally in the payload (it truncates `bash -s`); redirect stdin per command.
- Precedence ladder: recipe default < global < package < deployment < caller env. First claim wins. The registry and runbook snapshots are observation only, never sources (ADR-020).
- Shadow installers can swallow exit codes; assert postconditions.
- One branch per change; e2e merge gate before merging.

## Testing (TDD at the right level; the harness is acceptance, never the debugger)

Ladder, advance only when the current level is green: L0 `shellcheck` + `bash -n`; L1 a `bash -x` driver sourcing the phase files on the real target (no dispatch); L2 `cloudify --no-verify install`, read cloudify's log; L3 `cloudify verify` with `PKG_VERIFY_TIMEOUT=30`; L4 the bats harness, only as the final gate. Cheap proofs run on the tested container; localhost proves only shell semantics. One hypothesis per red cycle; never relaunch the same run.

### Run
- Scope by blast radius: the smallest set that can catch the change. Never debug with the full suite or E2E.
- Interface: `task test-unit`, `task test-integration:<pkg>`.
- Long runs go in the background; the run streams to `results/<name>.tap`. Poll it with plain `tail`, raw, no grep/sed. Never invent a log or an exit marker.
- Read cloudify's own log live: `/tmp/cloudify/logs/<ts>.log`.
- After a snapshot restore or container launch, wait for SSH/tailnet readiness before asserting.
- E2E once, at the end, on final HEAD. Push before remote tests (hosts pull from GitHub).

### Write
- Every `@test` opens with `rubric "<claim>"`; phases use `subrubric`; actions use `step` (`tests/helpers/report.bash`), timestamped.
- The helper writes to fd 9 when the runner opens it, so lines stream live through bats; otherwise stdout.
- Runner: `bats -T --show-output-of-passing-tests | tee results/<name>.tap`; prints the numbered plan (`1..N` is TAP's plan, not the report).
- Expensive one-time setup in `setup_file` with a readiness wait, never a `@test`.
- No custom logs in tests; `mktemp` for transient captures, print on failure.
- Keep tests focused; delete heavy E2E that duplicates a unit guard plus a lighter integration check.
- Bash parsing traps, one fix per class, not per instance: a tab is IFS whitespace, so `IFS=$'\t' read` collapses empty fields - emit machine-facing records with the unit separator `\x1f` at the source and parse on that (the house convention; a second `local x=""` mid-function also resets the parsed value). bats is pinned at 1.13.0 by `pkg/bats-test` - write parser-safe tests regardless (facts through a file + `<` redirection, single-word `-f` filters) so nothing depends on the version again.

Framework specifics: `task test-unit` runs bats in `cloudai:cloudify`; unit tests stub external commands (ssh, apt) and assert payload text/argv; `task lint` covers `lib/*.sh`, shadows, secrets, the router and all recipe phases.

## Security

- The registry (state under the ivps node dir) holds values and generated outputs: local, 0600, never committed to git. Runbooks carry structure + names only; any backup must be secret-aware.
- A file store must not inject framework control names; the deny-list lives in `lib/vars.sh`.

## Conventions

- Update `HISTORY.md` + `LOGS.md` every turn; end with `git status --short` clean.
- ADRs are numbered and append-only; plans live in `plans/`.
- `shellcheck` clean; lint covers `lib/*.sh`, `lib/shadows/*.sh`, `lib/secrets/*.sh`, `cloudify`, `pkg/*/{init,install,configure,uninstall,verify}.sh`.
