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
- **Fetch first.** GitHub is the sync bus between machines. Every session opens with `git fetch --all --prune`, and every remote-state claim rides on that same fetch; plain `git status` compares cached refs only.
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
- **Runbooks** (`lib/runbooks.sh`): repo-tracked Markdown plan (`runbooks/<app>/<flavor>/runbook.md`, the only discoverable shape: front-matter `targets:` + optional `inputs:`/`map:`, `bash step=<type>` fences). `cloudify app run <app>[/<flavor>] --name <name> --target <role>=<addr>` binds targets, preflights required vars, runs the steps (a `human-gate` step pauses), writes a run snapshot; `deployment replay` re-runs from one. See `runbooks/README.md`.
- **Direct state**: a bare package dispatch is a real deployment under the reserved `_direct` application, not an audit bucket. Names are allocated under the host lock (`<pkg>`, `<pkg>-2`, ...; explicit `--name` wins; values never name, so a reconfigure keeps its identity). State lives while the payload is deployed: a successful teardown deletes the record mechanically and the manifest once nothing remains; recorded values seed later dispatches; nameless commands resolve by candidates (package, host, values) - one equal candidate silently, otherwise list and stop. Sweeps are a debris backstop and never delete a named deployment's records (ADR-044, ADR-045).
- **Configuration**: `~/.config/cloudify/` (XDG, chmod 700). System credentials in `credentials` (remote/github/gitlab). Var sources, weakest to strongest: recipe default < global defaults (`remote-vars.yaml`) < package defaults (`pkgs/<pkg>.yaml`) < application defaults (`apps/<app>/defaults.yaml`) < application-flavor defaults (`apps/<app>/<flavor>/defaults.yaml`) < caller env (Defaults ladder, ADR-038; no per-deployment values file). Applied values and the user-forced bit live in the ivps inventory; secrets are environment-only (ADR-037), classified by `secret NAME` markers and anchored suffixes (ADR-042). Values may be secret references (`@backend:locator`, `@@` escapes). Loaded by `lib/vars.sh` (+ `lib/secrets.sh` backends); `lib/credentials.sh` loads only system credentials.
- **Remote payload**: `declare -f` extracts template body as literal text, `envsubst` with explicit allow-list substitutes only listed vars. Single-quoted `$VAR` references resolve on the remote side.
- **Install guards**: stateful packages use `CLOUDIFY_FORCE`/`CLOUDIFY_CLEAR_DATA` convention. See "Install Guards" in README.md.
- **Verification**: optional `pkg/<name>/verify.sh` defines `pkg_verify()`, sourced in a clean subshell by `_cloudify_run_verify` after every package (deep verify, incl. deps). `--no-verify` skips, `--verify`/`cloudify verify` is verify-only. See "Verification" in README.md.
- **Runtime manager**: mise (preferred). Legacy gvm/nvm/pyenv replaced.
- **Container OS**: Ubuntu 24.04

## SDLC

Review passes are bounded: a SPEC review gets one review pass, one fixing pass, and one verification pass; a Technical review gets at most three review/fix/verify passes. A verification pass that still finds must-fix findings escalates to Rachid - never another loop. Budgets are per reviewed artifact; when a budget is exhausted, stop and escalate. Reason: each extra loop iteration adds micro-drift that becomes truth in the next iteration, so drift multiplies.

TDD cycle. Tests run on the test host `cloudify` (an Incus container) through one plain ssh session (`tests/remote-bats.sh`), never on localhost.

**Test selection is delegated** (2026-10-18): the agent never picks the tests - under mission pressure that judgment over-tests or negotiates the rules away.
- Micro-step: spawn `persona: test-selector` (fresh context, read-only) with `Subject: git diff $(cat results/acceptance/GREEN)`; run `task test -- <its PICK files>` and nothing else. Its answer is never adjusted: an add, remove or reorder is a harness defect - fix `tests/SELECT.md` or `~/.pi/agents/test-selector/persona.md` (pi ignores `~/.agents/*.md`), note the bad case, re-spawn. Read its DROP reasons. No selector, no gate: run the unit suite and say why.
- Feature batch: the selected set plus the affected package's integration test. Milestone: `task acceptance`, the only writer of `results/acceptance/GREEN` and therefore the selector's diff baseline.
- Sanctuary (`tests/SANCTUARY.md`) guards are never pruned and always run when their surface is touched; anything else may be deleted if it freezes behavior nobody relies on or duplicates another guard. `tests/e2e/` runs at feature and milestone gates only.

**Two scopes** (2026-10-01): one change never pays both costs - a tool change runs the selected set, a package change runs `task test-integration:<pkg>` (plus its unit files if any).

**Skills:** before editing cloudify or a package, read the `cloudify-dev` skill (framework) or the `cloudify-pkg-dev` skill (recipes); the bats harness is the completion gate, never the debugger.

**Prerequisites:** Incus, `ivps` CLI, the running test host `cloudify`.

```bash
task setup-container   # one-time: bats + libraries on the test host
task test -- <files>   # the selector's PICK set (selection is delegated, above)
task test-unit         # the whole unit suite: only when the selector cannot run
task lint              # shellcheck on this host
```

**Evidence:** long runs are detached (`setsid <cmd> </dev/null >/dev/null 2>&1 &`); `tests/remote-bats.sh` keeps `results/<name>.tap` pointing at the run's `report.tap`, which carries each failure's assertion and output. Read TAP raw; hand a large TAP to a subagent for the failures only. All authored test/runner code lives in `tests/` (`tests/red/` for explicit-invocation reproducers, transient tests included); `~/tmp` holds run data only.

**Implementation:** the lead agent writes the code and shows the moves; subagents review, research, and read large taps.

**Logs and observability:** LOGS section below. Native logs only, raw; never redirect, filter or discard.
**Test transport:** plain `ssh root@X` (Tailscale SSH, no options, no incus daemon) is the only test transport: one ssh session streams the tree to the test target (`X` = `CLOUDIFY_TEST_TARGET`, default `cloudify`), runs bats there, streams the TAP back live, and the ssh exit is the run's exit. Never `ivps exec`, never the incus API, never per-command round trips, never backgrounded remote runs. A repeat of the improvisation trap escalates to Rachid immediately.

**Planning:** one plan at a time, `PLAN.md` → symlink to `plans/<current>.md`. `plans/` holds plans only; finished plans move to `plans/archived/`. If the plan stops flying, raise it with Rachid rather than forking a second plan. Issues/PRs document outcomes; plans reference issues. Canonical docs (`PLAN.md`/`HISTORY.md`/`LOGS.md`) own progress and evidence; scratch files never become the tracking authority.

**Versioning:** strict SemVer. The `VERSION` file at the repo root is the single source; `cloudify --version` prints it; `CLOUDIFY_VERSION` overrides it in tests. Bump per semver whenever the tool meaningfully changes (breaking: MAJOR, behavior/features: MINOR, fixes: PATCH).

**Normative files:** the design (`REDESIGN.md`) and the plan (`plans/<current>.md` via `PLAN.md`) are the single source of truth. Everything else is a working note I may use freely, except `schemas/v1/` (machine-enforced), `AGENTS.md` (process) and `LOGS.md`/`HISTORY.md` (required records). Every spec or plan change must land in a normative file, and a design change lands in `REDESIGN.md` in the same commit as the decision that authorizes it.

**ADRs:** self-contained, never referencing a path that can move or be deleted. `REDESIGN.md` and `PLAN.md` are the only stable references an ADR may name.

**Naming:** reference every step, phase and entry by a human-readable name with its id in parentheses, never the bare id.

**Issues:** filed on GitHub (`github.com/rachidbch/cloudify`), not as local markdown.
**PRs:** `git push -u origin <branch>` then `gh pr create`.

**Turn closure:** each turn ends with ALL docs updated (README.md, HISTORY.md, pkg READMEs, AGENTS.md) + `git status --short` clean. Missing a HISTORY entry is a bug.

**Recipe conventions:** see "Directory structure" and "Recipe conventions" in README.md. Packages with non-obvious config/exposure/gotchas ship a `README.md` (and `docs/` if needed) — update it alongside the recipe.


## LOGS

Cloudify's native evidence channels - always these, always raw:

- Every dispatch writes a full transcript on this machine: `/tmp/cloudify/logs/<YYYYMMDD-HHMMSS>.log` (the path is printed in the run's summary line). The same basename is written on the target host under its `/tmp/cloudify/logs/`, with a `latest.log` symlink there. `latest.log` does not exist on the controller.
- bats suites stream to `results/<name>/report.tap` via `--report-formatter tap13`.
- Read raw (`cat`, `tail`). No filters, no pipes, no `>/dev/null`, no discarding dispatch stdout: filtered or discarded output is destroyed evidence and repeats failures.
- Read the log before forming any hypothesis. Fix one issue, push, re-test.

## Working Plan

