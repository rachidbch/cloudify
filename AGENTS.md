# Cloudify

## ⛔ Fragile surface — read before touching these files

Fails silently, kills every install: value propagation (`lib/remote.sh`,
`lib/vars.sh`, `lib/context.sh`) and shadows (`lib/shadows/`, `lib/shadow.sh`).

Before editing any of them:
1. Read `docs/FRAGILE.md` - the invariants and the test pinning each one.
2. Name in the plan or commit which invariants you touch; run `task gate`;
   byte-exact goldens unchanged.
3. Changing a contract (order, format, ownership) or a pinning test -> Rachid's go.

Everything else: plain TDD, no gate.

## Constitution (project-specific; global rules in ~/AGENTS.md)
- **Fail fast on test-env trouble; never heal the environment mid-tests.** A red environment (host-key churn, container recreated, probe timeouts, wiped results) is a STOP and a ping to Rachid with the evidence - not `ssh-keygen -R`, re-accepts, re-syncs, or silent relaunches. Healing mid-ladder hides the fault and burns hours on reruns of runs that were never going to hold.
- **Timeouts.** Estimate task time, set 3×. Never fail a command by being too conservative.
- **Tool priority.** cloudify > ivps > incus; incus only with explicit consent.
- **Verify stuck before killing.** A slow mutating op isn't a hang - confirm no progress (D-state, zero I/O) first. Mid-op kills leave dirty state that breaks the next run.
- **Docs before code, logs before hypotheses.** Read README/AGENTS + logs before diagnosing; never assert an unconfirmed root cause.
- **Superseded ADRs need surfaced consent.** ADRs are append-only, so a newer ADR contradicting an older one is normal and must not stop work. But when a decision departs from an agreed-upon ADR, surface the departure first and get explicit, well-informed consent - never follow the supersession chain silently.

## Conventions

- **`--on <target host>`** comes BEFORE the action verb: `cloudify --on host install pkg`.
  Grammar: `X` (must exist; kind discovered), `X:` (a node), `X:Y` (an instance on node X),
  `:Y` (an instance on the active node). Active = `CLOUDIFY_NODE` (`cloudify node use <node>`
  prints the export; else the ivps default). No localhost fallback; install never provisions.

## Project

Bash-based host provisioning and package management for Ubuntu/Debian. Two components:

1. **GitHub repo** (`github.com/rachidbch/cloudify`) — CLI router (`cloudify`) + `lib/` modules + `pkg/` recipes + `tests/`
2. **Bootstrap gist** — remote hosts curl this to clone/pull the repo and symlink the CLI

**Remote hosts run code from GitHub, not local checkout.** Push before integration tests.

## Architecture

- **Module pattern**: each `lib/*.sh` has a guard `_CLOUDIFY_X_LOADED`. Sourced by the router, not by each other.
- **Plugin API**: `pkg_*` functions in `lib/package-api.sh`. Signatures are stable — used by 75+ packages.
- **Shadow commands**: `lib/shadows/*.sh` override `sudo`, `apt-get`, `add-apt-repository`, `git` with wrappers for password injection, idempotency, auth. Recipes call bare commands — shadows handle the rest.
- **Targets** (`lib/targets.sh`): resolve an `--on` target host to (node, instance, ssh host); ivps is the inventory provider; validation only, never provisioning.
- **Registry** (`lib/registry.sh`): legacy records at `$(ivps node path <node>)/[<instance>/]deployments/<id>/pkgs/<pkg>/config.yaml` (cloudify-owned fallback bucket when no node resolves), read-only at runtime; migration consumes them, `deployment delete` sweeps. Never a precedence source (ADR-020).
- **Runbooks** (`lib/runbooks.sh`): repo-tracked Markdown plan (`runbooks/<app>/<flavor>/runbook.md`, the only discoverable shape: front-matter `deployment` + `targets`, `bash step=<type>` fences). `cloudify deployment run <id>` binds targets, preflights required vars, runs the steps (a `human-gate` step pauses), writes a run snapshot; `deployment replay` re-runs from one. See `runbooks/README.md`.
- **Configuration**: `~/.config/cloudify/` (XDG, chmod 700). System credentials in `credentials` (remote/github/gitlab). Var sources, weakest to strongest: recipe default < `remote-vars.yaml` (global) < `pkgs/<pkg>.yaml` (package) < `apps/<app>/<flavor>/defaults.yaml` (application defaults) < `deployments/<app>/<flavor>/<name>/values.yaml` (deployment) < caller env; a name forwards only if a `.remote-vars` declaration or a file store knows it. Values may be secret references (`@backend:locator`, `@@` escapes). Loaded by `lib/vars.sh` (+ `lib/secrets.sh` backends); `lib/credentials.sh` loads only system credentials.
- **Remote payload**: `declare -f` extracts template body as literal text, `envsubst` with explicit allow-list substitutes only listed vars. Single-quoted `$VAR` references resolve on the remote side.
- **Install guards**: stateful packages use `CLOUDIFY_FORCE`/`CLOUDIFY_CLEAR_DATA` convention. See "Install Guards" in README.md.
- **Verification**: optional `pkg/<name>/verify.sh` defines `pkg_verify()`, sourced in a clean subshell by `_cloudify_run_verify` after every package (deep verify, incl. deps). `--no-verify` skips, `--verify`/`cloudify verify` is verify-only. See "Verification" in README.md.
- **Runtime manager**: mise (preferred). Legacy gvm/nvm/pyenv replaced.
- **Container OS**: Ubuntu 24.04

## SDLC

Review passes are bounded: a SPEC review gets one review pass, one fixing pass, and one verification pass; a Technical review gets at most three review/fix/verify passes. A verification pass that still finds must-fix findings escalates to Rachid - never another loop. Budgets are per reviewed artifact; when a budget is exhausted, stop and escalate. Reason: each extra loop iteration adds micro-drift that becomes truth in the next iteration, so drift multiplies.

TDD cycle. All tests run inside an Incus container (`cloudai:cloudify`), never on localhost.

**Two products, two test scopes** (ruled 2026-10-01): cloudify is the tool AND a pkg registry; never pay both costs for one change.
- cloudify code change (`cloudify`, `lib/`, `schemas/`, tool tests): full unit + gate + `task test-canary` (guacamole, the complex pkg). Full pkg sweep only at milestones.
- pkg change: `task test-integration:<pkg>` only, plus that pkg's unit tests if it has any.

**Skills:** before editing cloudify or a package, read the `cloudify-dev` skill (framework) or the `cloudify-pkg-dev` skill (recipes); the bats harness is the completion gate, never the debugger.

**Prerequisites:** Incus, `ivps` CLI, running container `cloudai:cloudify`.

```bash
task setup-container   # One-time: install bats + libraries
task test-unit         # Push + unit tests
task test              # Push + all tests (unit + integration)
task lint              # shellcheck on this host
```

**Testing:** tests run in `cloudai:cloudify` only; `task sync` rsyncs the tree (prunes deletions), integration tests also need the branch pushed.
Background + poll, never redirect or grep: `mkdir -p results/<suite>`; `setsid <cmd> --report-formatter tap13 -o results/<suite> </dev/null >/dev/null 2>&1 &`; then `tail results/<suite>/report.tap`. bats always names it `report.tap`, and stdout must be discarded or SIGPIPE kills it when the ssh channel closes. tap13 carries each failure's assertion and output, so the tap suffices; give a large tap to a subagent for the failures only.
Full suite at phase and milestone boundaries; E2E is an exit gate, never a debugger.

**Implementation:** the lead agent writes the code and shows the moves; subagents review, research, and read large taps.

**Logs and observability:** Two channels only, for debugging, background tasks and agent observability alike: cloudify's live log (`/tmp/cloudify/logs/latest.log`) and the run's TAP (`results/<suite>/report.tap`). Read them before forming any hypothesis; improvised repro scripts, custom logs and test-output greps are forbidden. Fix one issue, push, re-test.
**Test transport:** plain `ssh root@X` (Tailscale SSH, no options, no incus daemon) is the only test transport: one ssh session streams the tree to the test target (`X` = `CLOUDIFY_TEST_TARGET`, default `cloudify`), runs bats there, streams the TAP back live, and the ssh exit is the run's exit. Never `ivps exec`, never the incus API, never per-command round trips, never backgrounded remote runs. A repeat of the improvisation trap escalates to Rachid immediately.

**Planning:** one plan at a time, `PLAN.md` → symlink to `plans/<current>.md`. `plans/` holds plans only; finished plans move to `plans/archived/`. If the plan stops flying, raise it with Rachid rather than forking a second plan. Issues/PRs document outcomes; plans reference issues.

**Versioning:** strict SemVer. The `VERSION` file at the repo root is the single source; `cloudify --version` prints it; `CLOUDIFY_VERSION` overrides it in tests. Bump per semver whenever the tool meaningfully changes (breaking: MAJOR, behavior/features: MINOR, fixes: PATCH).

**Normative files:** the design (`REDESIGN.md`) and the plan (`plans/<current>.md` via `PLAN.md`) are the single source of truth. Everything else is a working note I may use freely, except `schemas/v1/` (machine-enforced), `AGENTS.md` (process) and `LOGS.md`/`HISTORY.md` (required records). Every spec or plan change must land in a normative file, and a design change lands in `REDESIGN.md` in the same commit as the decision that authorizes it.

**ADRs:** self-contained, never referencing a path that can move or be deleted. `REDESIGN.md` and `PLAN.md` are the only stable references an ADR may name.

**Naming:** reference every step, phase and entry by a human-readable name with its id in parentheses, never the bare id.

**Issues:** filed on GitHub (`github.com/rachidbch/cloudify`), not as local markdown.
**PRs:** `git push -u origin <branch>` then `gh pr create`.

**Turn closure:** each turn ends with ALL docs updated (README.md, HISTORY.md, pkg READMEs, AGENTS.md) + `git status --short` clean. Missing a HISTORY entry is a bug.

**Recipe conventions:** see "Directory structure" and "Recipe conventions" in README.md. Packages with non-obvious config/exposure/gotchas ship a `README.md` (and `docs/` if needed) — update it alongside the recipe.


## Working Plan

