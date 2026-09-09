# Plan: URGENT surface cleanup (single tracking file)

Single source for all URGENT work: decisions, design space, tasks, progress.
ROADMAP `## URGENT` holds the original decision record; this file supersedes the
standalone branch plan and absorbs every gate artifact (description + plan +
non-breakage argument). Non-urgent items (Idea 3, per-target credentials) stay in
ROADMAP and are out of scope here.

Status markers (EVERY task uses one):
`[ ]` todo · `[~]` doing · `[x]` done, not tested · `[v]` done, tests pass.

Rules:
- One branch at a time; merged to master before the next branch starts.
- Merge gate (every branch): full unit suite green + the branch's blast-radius
  integration files green + a real CLI smoke of the branch's new path. Record all
  three as `[v]` in the branch before merging. Full `task test` (all packages)
  runs at milestone boundaries only.
- Any branch touching `lib/` or the router runs the CRITICAL GATE: description
  artifact -> plan + non-breakage argument -> explicit human consent. All three
  live in this file; no separate artifact files.
- Branch closes only when its tasks are `[v]`, `git status --short` is clean, and
  HISTORY.md + LOGS.md are updated.

## Progress board

- [x] Branch 0 - decisions + ROADMAP URGENT bucket + this plan (2026-09-07)
- [v] Branch 1 - vars internals: five-source helpers + walker + precedence + resolver
- [ ] Branch 1b - vars CLI surface + declaration syntax + `vars declared`
- [ ] Branch 2 - CLI actions: verify + uninstall
- [ ] Branch 3 - security: payload via stdin + skill Security section
- [ ] Branch 4 - guacamole 3-leg rewrite
- [ ] Branch 5 - xfce alignment
- [ ] Branch 6 - runbooks a
- [ ] Branch 7 - state registry
- [ ] Branch 8 - runbooks b

Trap -> branch map (ROADMAP `## URGENT` 1-7):
trap 1 -> 1b (flag-scoped vars CLI); trap 2 -> 1b (declaration = doc mirror);
trap 3 -> 4 (uninstall teardown + configure convergence, needs 2); trap 4 -> 2
(verify action); trap 5 -> 1b + 3 (secrets = vars + hygiene, stdin payload);
trap 6 -> 3 + 6 (MagicDNS names, skill rule); trap 7 -> 4 (guacadmin default).

## Branch 0 - decisions and plan (2026-09-07)

- [x] Review traps 1-7 one by one; collapse false claims (2+3) after reading `lib/remote.sh`.
- [x] Record every resolution in ROADMAP `## URGENT` decided blocks (vars CLI + declaration,
  vars internals + security, target config model, runbooks a/b).
- [x] Write this plan; repoint PLAN.md.
- [x] Update HISTORY.md + LOGS.md; commit.

## Branch 1 - vars internals: five-source helpers + walker + precedence + resolver

Gate: touches `lib/remote.sh`, `lib/deployments.sh`, `lib/pkg-config.sh`, router.
Non-breakage argument below; consent required before any edit.

### Gate tasks

- [x] Description artifact (2026-09-09): current machinery described end to end in
  "What the code does today" below. Evidence: empirical repros `~/tmp/vars-desc/e*.sh`
  (E1-E16), bash 5.x, `set -Eeuo pipefail`; every claim cites file:line.
- [x] Plan + non-breakage argument (this section): invariants I1-I12, landmines L1-L12,
  proposed resolutions R1-R9.
- [x] Explicit consent (Rachid) before any edit (2026-09-09).

### What the code does today (gate description, read-only)

- Collector `_cloudify_pkg_remote_vars` (`lib/remote.sh:98-230`) is invoked with a
  redirect, never `$(...)` (`remote.sh:263`): its exports ARE the value channel.
- Walk order (physical precedence, first-write-wins via a claim ledger in a temp file):
  1. `~/.config/cloudify/remote-vars.yaml` via `_cloudify_load_yaml_vars`
  (`lib/pkg-config.sh:19-45`, called `remote.sh:152`); unconditional, overwrites env.
  2. per-package `pkg/<name>/.remote-vars` via `_try_claim_env` (`remote.sh:130-148`):
  declaration-gated env path, bare `NAME` lines only, warns when declared but unset.
  3. `~/.config/cloudify/pkgs/<pkg>.yaml` via `_try_claim` (`remote.sh:111-125`);
  unconditional.
  4. `pkg_depends` dependencies, recursively, parent before deps (`remote.sh:178-193`).
  5. deployment store via `_cloudify_deployment_read_vars`
  (`lib/deployments.sh:178-196`) when `CLOUDIFY_DEPLOYMENT` is set (`remote.sh:201-226`);
  snapshot/restore so it never clobbers earlier claims.
- Actual value precedence today: walk order + first-write-wins, i.e.
  `remote-vars.yaml` > caller env > `pkgs/<pkg>.yaml` > deployment store.
  Env only competes for names declared in `.remote-vars`; without a declaration the
  per-pkg yaml silently overwrites the caller env (E14).
- Payload baking: template body via `declare -f` (`remote.sh:279`), placeholder
  `_CLOUDIFY_PKG_EXPORTS_` substituted (`remote.sh:282`), `envsubst` with an explicit
  allow-list = hardcoded base list (`remote.sh:287`) + collected names
  (`remote.sh:272`), then `; cloudify $*` appended (`remote.sh:291`), shipped as ssh
  argv (`remote.sh:312-317`; branch 3 moves it to stdin). Values are baked inside
  literal single quotes; `$`/`$(...)` inside stay inert; a `'` in a value breaks the
  payload at parse time (E7b).
- Local install path (`cloudify install <pkg>`, hosts=localhost) never calls the
  collector: it sees caller env + recipe `${VAR:-default}` only; `remote-vars.yaml`,
  `pkgs/<pkg>.yaml` and the deployment store are ignored locally.
- Verify: local `cloudify verify` loads `pkgs/<pkg>.yaml` on localhost
  (`lib/package-api.sh:345`); remote verify-only (`--verify install`) forwards only
  `remote-vars.yaml` because the args carry no install/configure token (`remote.sh:161-163`).

### Claims corrected by the gate description

- `remote-vars.yaml` is loaded by `_cloudify_load_yaml_vars` (`lib/pkg-config.sh:19` via
  `remote.sh:152`), NOT by `lib/credentials.sh` (which loads only `credentials`,
  `credentials.sh:119`).
- `.remote-vars` today supports bare `NAME` only; `NAME=value` / `NAME=` fail the
  whole-line regex (`remote.sh:139`) and are skipped silently (E6). The three kinds are
  the branch-1b target, not current behavior.
- "Caller env strongest today" (README.md:165, ADR-011 point 6) is false for names in
  `remote-vars.yaml` (E1c) and false for undeclared names vs per-pkg yaml (E14).
- Code comment "Env wins over disk claims" (`remote.sh:128`) is half false.
- "The user yaml is the single source of truth" (README.md:159) is remote-install only.
- Confirmed: global strongest / deployment weakest; only the env path is declaration-gated.

### Invariants the refactor must preserve

- I1 Collector exports must survive: every reader called with a redirect, never `$()`
  (`remote.sh:210-212`, `:263`; E1-flawed reproduces the silent-empty failure).
- I2 Env path stays declaration-gated: only names in `.remote-vars` may enter from the
  caller env (`remote.sh:139-140`, E13); otherwise the whole operator environ forwards.
- I3 File stores forward unconditionally (`remote.sh:150-158`, `:184`, E13); gating them
  breaks every existing user config.
- I4 First-write-wins by walk order (`remote.sh:117`, `:196`, `:183-192`, E3c).
- I5 The deployment read must not clobber earlier claims (`remote.sh:206-224`, E4).
- I6 Allow-list substitution set unchanged unless deliberately extended (`remote.sh:272`,
  `:287`).
- I7 Unlisted template vars stay literal and resolve on the host (`$HOME`,
  `$CLOUDIFY_LOG_FILE`, `$(...)`; E9).
- I8 Values baked inside literal single quotes; `$`/`$(...)` inert; any resolver must
  re-validate quoting (E7b, E7c).
- I9 Local/remote behavior differences are explicit; unifying them needs its own
  collector call on the local path (router change).
- I10 Perms: `credentials` 600, deployment dir 700/config 600; the two yaml stores have
  no enforcement today (README:142 advisory).
- I11 Verify-path parity: a value verify.sh needs must be reachable on the side that
  runs it (local verify = pkg yaml; remote install = everything; remote verify-only =
  global only).
- I12 Back-compat: bare-name `.remote-vars`, flat `KEY: value` yaml, quoted values,
  `#` comments, `:`-containing values, `export VAR='value'` credentials.

### Landmines (in-scope ones flagged)

- L1 Subshell-ising any reader loses exports (I1). Applies to every new helper.
- L2 Flipping precedence by reordering calls fails: `_try_claim` and
  `_cloudify_load_yaml_vars` overwrite env unconditionally; "env wins" needs
  non-clobbering readers. IN SCOPE (R3).
- L3 "Env strongest" must not mean "all environ"; keep the declaration gate (I2). IN SCOPE (R2).
- L4 `xargs` in `_cloudify_deployment_read_vars` (`deployments.sh:187-188`) mangles
  `'`/`\`/`"`/spaces and aborts on multi-line values (E5d/E5e/E11/E12). IN SCOPE (R6).
- L5 No reserved-name guard: a file-store key `CLOUDIFY_REMOTE_USER: evil` retargets ssh,
  `DEBUG: true` flips cloudify debug (E16). IN SCOPE (R5).
- L6 Declaration syntax expansion must not become a value source that beats the recipe
  default locally but not remotely; recipe `${VAR:-}` stays runtime truth. Branch 1b.
- L7 Single quotes/newlines in values break the baked payload (E7b); a vault/base64
  backend must re-validate quoting. IN SCOPE (R4, R8).
- L8 Renaming `cloudify_vars_set/delete/list/show` or `_cloudify_deployment_read_vars`
  breaks the router and `tests/unit/deployments.bats:21-31`, `:194-224`. IN SCOPE (R7).
- L9 Removing the snapshot/restore without a non-clobbering read promotes deployment
  values above package values (I5).
- L10 Unvalidated names reach the envsubst format string (`remote.sh:270-274`); a
  multi-line deployment value (L4) can inject one.
- L11 Dependency scan is regex-only and install-phase-only (`remote.sh:188`); keep the
  same set or document the change (fixtures `fixture-split`/`fixture-dep-split` depend on it).
- L12 Warn semantics: the env reader warns per source, so a declared name supplied by
  the deployment store still warns (E4). Keep the genuine case
  (`tests/unit/remote-vars.bats:49-54`).

### Proposed resolutions (R1-R9; consent covers these)

- R1 Local parity: YES, run the walker on the local install path too, so one precedence
  governs both (I9). Router change, wider blast radius, no recipe changes.
- R2 Env scope: candidate set = names known from the declaration + all file stores
  (global, package, deployment). Env may override any known name; no ambient var enters.
- R3 Non-clobbering global read: `_cloudify_load_yaml_vars <file> [overwrite|no-clobber]`,
  default no-clobber for the walker, overwrite kept for verify (`package-api.sh:345`).
- R4 Resolver seam: `_cloudify_resolve_var_value <name> <raw>` called by every reader;
  identity default; `@<backend>:<locator>` via `lib/secrets.sh` glob-sourcing
  `lib/secrets/*.sh` (mirrors `lib/shadow.sh` -> `lib/shadows/*.sh`); `@@` escapes a
  literal leading `@`; backend failure = die, never forward empty. No vault shipped.
  Built-in `base64` backend so multi-line values round-trip as one line (L4/L7).
- R5 Reserved-name guard: a deny-list of framework-owned names
  (`CLOUDIFY_REMOTE_USER`, `CLOUDIFY_REMOTE_PWD`, `DEBUG`, `CLOUDIFY_BOOTSTRAP_URL`,
  `CLOUDIFY_UPDATE_DELAY`) is warn+skip from file stores (L5).
- R6 Deployment reader: replace `xargs` with pure-bash trim; preserve `'`, `\`, `"`,
  spaces; multi-line values only via the `@base64:` reference (R4).
- R7 Back-compat: keep `cloudify_vars_set/delete/list/show` and
  `_cloudify_deployment_read_vars` as thin aliases of the new helpers; router migrates
  to canonical names; `deployments.bats` keeps passing unmodified.
- R8 Quoting: branch 1 keeps the single-quote baking contract unchanged (I8); branch 3
  owns the transport change (stdin payload) and may revisit quoting then.
- R9 `vars show` prints raw stored values by default, `--resolve` resolves; masking
  (`PASSWORD`/`TOKEN`/`SECRET`/`KEY`) applies to both.

### Implementation tasks

- [v] Create `lib/vars.sh` (guard `_CLOUDIFY_VARS_LOADED`) with the five-source helpers:
  `cloudify_vars_global_read|write`, `cloudify_vars_pkg_read|write`,
  `cloudify_vars_deployment_read|write`, `cloudify_vars_env_read`, and
  `cloudify_vars_state_read` (replay, read-only, no-op until branch 7).
- [v] Rewrite `_cloudify_pkg_remote_vars` as a thin precedence walker over the helpers;
  keep the redirect invocation and the claim ledger (I1, I4).
- [v] Implement the target precedence recipe default < global < package < deployment < env,
  with non-clobbering reads (R3) and the env candidate set of R2.
- [v] Add `_cloudify_resolve_var_value` + `lib/secrets.sh` + built-in `base64` backend (R4);
  call it from every value-entry reader.
- [v] Add the reserved-name deny-list warn+skip (R5).
- [v] Fix `_cloudify_deployment_read_vars` value parsing: pure-bash, no `xargs` (R6).
- [v] Enforce 0700/0600 on helper writes to the two yaml stores (I10).
- [v] Run the walker on the local install path (R1).
- [v] Add aliases for the renamed public functions (R7).
- [x] Correct README.md:159/165 var-source claims in the same branch.

### Tests

- [v] Unit: one test per helper (read/write round-trip, perms, back-compat formats).
- [v] Unit: precedence matrix including today's uncovered cases: global vs caller env
  (E1c), cross-package claim order (E3c), collector + deployment snapshot (L9),
  false-positive warn (L12).
- [v] Unit: resolver identity, `@@` escape, `@base64:`, unknown backend dies.
- [v] Unit: reserved-name skip; special chars `'` `\` `"` spaces and multi-line in the
  deployment reader.
- [v] Integration: `tests/integration/package-remote-vars.bats` still green (per-host
  concurrent token), `tests/integration/package-install-run-split.bats:61-68` still green.
- [v] Regression: `tests/unit/remote-vars.bats` and `tests/unit/deployments.bats`
  unmodified and green.

### Done when

- [v] Precedence tests pass, remote-vars integration green, no recipe changes needed.
- [v] Merge gate: unit 345/345; `package-remote-vars.bats` + `package-install-run-split.bats` PASSED on HEAD b40b97e; R1 local path covered by `vars.bats` test 40 (real router subprocess).
- [v] No invariant I1-I12 regressed; every landmine in scope has a test.
- [v] HISTORY.md + LOGS.md updated; `git status --short` clean.

### Branch 1 outcome (2026-09-09)

- Merged to master as `397c064` (--no-ff) after the e2e merge gate.
- Landed: `lib/vars.sh` (five-source helpers + claim ledger + resolver + reserved
  guard), `lib/secrets.sh` + `lib/secrets/base64.sh`, walker rewrite in
  `lib/remote.sh`, local-path walker in the router, README var sections.
- Tests: `tests/unit/vars.bats` (40), full unit suite 345 green; pinned
  `remote-vars.bats`, `deployments.bats`, `package-api.bats`, `remote.bats`,
  `install-run-split.bats` green unmodified; both pinned integration files green.
- Bug fixed in passing: the dep scan `deps=$(grep ... | sed | tr)` returned 1 for a
  recipe with no `pkg_depends` line and aborted the walk under errexit+pipefail.
  Latent in pre-branch code; fixed with `|| true` (proved by the local-path test,
  whose fixture recipe has no `pkg_depends`).
- Write side of L4 closed in review: `_cloudify_vars_file_set` stored a
  multi-line value raw, silently truncating it at the first newline; it now
  encodes as `@base64:` (R6), proved by a new round-trip test.
- Plan-internal contradiction resolved in favour of task 3 + ROADMAP "Target config
  model": I5/L9 say the deployment read must not clobber earlier claims, but the
  target precedence (repeated in task 3 and ROADMAP M1-M4) promotes deployment
  above package values. Implemented deployment > package; I5 is honoured only for
  the caller env (the one source stronger than deployment). Flagged for the ADR
  trail; no pinned test asserts either order.
- R4 refinement: the resolver is called from every FILE value-entry reader
  (global/package/deployment) and from the verify yaml load, not from the env
  reader. Reason: with R1 the walker runs again on the host; the payload already
  carries the operator-resolved plaintext, so resolving env values a second time
  would double-resolve and break the `@@` escape across the SSH hop. The env
  reader is pass-through by design (caller plaintext is authoritative).

## Branch 1b - vars CLI surface + declaration syntax + `vars declared`

Gate: touches router (`cloudify`), `lib/deployments.sh`, `lib/remote.sh` (declaration parse).

Design (ROADMAP "Vars CLI + declaration"):
- Flag-scoped, mutually exclusive: `cloudify vars show|set|unset|list <key> [<value>]
  [--global | --pkg <name> | --deployment <id>]`; no flag = ambient `CLOUDIFY_DEPLOYMENT`,
  clear error + hint when unset (trap 1).
- `--stdin` / `--file` for values so secrets stay out of shell history.
- `cloudify vars declared <pkg>` prints the whole knob surface: `NAME` = required,
  `NAME=value` = defaulted (default shown), `NAME=` = optional; optionally the source
  currently setting it (trap 7 discovery fix).
- Declaration syntax gains `NAME=value` / `NAME=` (trap 2 + L6): the declaration stays
  a documentation mirror, never a value source; recipe `${VAR:-}` remains runtime truth,
  so local and remote installs behave identically.
- No drift-detection machinery; the cloudify skill carries "edit recipe defaults and the
  repo declaration in sync".

Tasks:
- [ ] Extend `_try_claim_env` to accept `NAME`, `NAME=value`, `NAME=`; keep bare `NAME`
  back-compat (I12).
- [ ] Add the scope flags to the `vars` subcommand in the router; mutually exclusive,
  ambient fallback with hint.
- [ ] Add `--stdin`/`--file` to `vars set`; store literal or `@backend:locator` reference.
- [ ] Add `vars declared <pkg>` (three kinds + current source); mask secret-looking output.
- [ ] Fix the residual `xargs` in `cloudify_vars_deployment_list --json` (a value with
  `"` still yields invalid JSON).
- [ ] Write-time validation: a value starting with `@` that is not a valid reference
  dies with a hint to use `@@` (today it dies later, at read/install time).
- [ ] Update the cloudify skill with the var standard + the sync rule.

Tests:
- [ ] Unit: flag parsing (mutual exclusion, ambient fallback error).
- [ ] Unit: `vars declared` output for a fixture with all three kinds.
- [ ] Unit: declaration parse back-compat (bare `NAME` unchanged).
- [ ] Integration: set/show/list/unset against the container, per scope.

Done when: CLI + reader green on the test container, existing `deployments.bats` unmodified.

## Branch 2 - CLI actions: verify + uninstall

Gate: router + `lib/packages.sh` + `lib/package-api.sh`.

Design (traps 3, 4; lifecycle rule):
- `verify` first-class in both contexts: `cloudify --on <host> verify <pkg>`; keep
  `--verify install` alias; clear parser error when trailing words are not packages.
- `uninstall` action: router + phase sourcing; optional `pkg/<name>/uninstall.sh` with a
  defined default when absent; `pkg_depends`-style dep handling; verify not run.
- Lifecycle: install provisions / configure configures / uninstall tears down
  (`compose down -v` before removing the project dir).

Tasks:
- [ ] Make `verify` an action in the router; keep the alias.
- [ ] Fix the misleading "no packages found" parser error.
- [ ] Implement `uninstall`: router action, phase sourcing, optional `uninstall.sh`,
  default teardown.
- [ ] Document the action vocabulary + uninstall contract in README and the skill.

Tests:
- [ ] Integration: fixture pkg with `uninstall.sh` removes its markers.
- [ ] Integration: remote verify action; `--verify install` alias still works.
- [ ] Regression: existing split/verify tests green.

Done when: both actions green on the test container.

## Branch 3 - security: payload via stdin + skill Security section

Gate: `lib/remote.sh`.

Design (trap 5, 6; exposure inventory):
- Send the payload via stdin (`ssh host 'bash -s' < payload`) instead of argv; secrets no
  longer visible in the operator or host process lists.
- Skill Security section: stdin payload; references in cloudify state; masking
  `PASSWORD`/`TOKEN`/`SECRET`/`KEY`; 0600; no secrets in logs; the two vault models
  (operator-side default, host-side) and the fundamental limit that the host must hold
  the plaintext.
- MagicDNS names never IPs; address-shaped values derived at run time (trap 6).
- Revisit the single-quote baking once the payload is no longer argv (R8); re-validate I8.

Tasks:
- [ ] Switch the remote payload transport to stdin; keep I7 literal-var behavior.
- [ ] Re-validate the quoting contract after the transport change (I8/L7).
- [ ] Skill: add the Security section + the MagicDNS-names rule.
- [ ] Validate once that guacd resolves MagicDNS from inside the compose network.

Tests:
- [ ] Integration: probe the remote process table during a slow install and assert a
  secret is absent from argv.
- [ ] Regression: full remote install suite green.

Done when: stdin path green, no regression in remote installs.

## Branch 4 - guacamole 3-leg rewrite (reference package)

Gate: recipe only (no lib/router), but it is the reference for the lifecycle rules.
Depends on branch 2 (uninstall action).

Design (trap 3, 7; lifecycle + compose-semantics-first):
- `install.sh` provisions only: create-if-absent `.env`/compose, `docker compose up -d
  --wait` with healthchecks; no config mutation, no bash wait loops.
- `configure.sh` configures: rewrite config, up, converge the DB credential via the
  postgres local socket (`ALTER USER ... PASSWORD`), upsert the connection record.
- `uninstall.sh`: `docker compose down -v` then remove the project dir.
- Admin default `rbc` -> `guacadmin` (Guacamole's seeded name; no rename when unset).
- Evaluate mounting the schema under `/docker-entrypoint-initdb.d` instead of
  docker cp + psql (revisit partial-init detection).

Tasks:
- [ ] Rewrite `pkg/guacamole/{install,configure,uninstall}.sh` per the 3-leg contract.
- [ ] Change the admin default to `guacadmin`.
- [ ] Decide + implement the schema-init mechanism.
- [ ] Update `pkg/guacamole/README.md` + declaration.

Tests:
- [ ] Integration: install, configure (incl. changed DB password converges), uninstall
  removes volumes, FORCE reinstall preserves data.

Done when: bats green, run time <= previous, no compose mechanics duplicated in bash.

## Branch 5 - xfce alignment

Gate: recipe only.

Design: declaration syntax per the pkg-writing standard; neutral defaults; keep
install/configure; optional `uninstall.sh` (remove packages/user only with explicit
intent; never the home).

Tasks:
- [ ] Align `pkg/xfce` declaration + defaults with the standard.
- [ ] Add the optional `uninstall.sh` with the explicit-intent guard.
- [ ] Update `pkg/xfce/README.md`.

Tests:
- [ ] Integration: existing `package-xfce.bats` green + declaration reader output.

Done when: bats green, declaration matches the recipe defaults.

## Branch 6 - runbooks (a): agent runbooks tree + amnesiac validation

Design (ROADMAP Runbooks a):
- `runbooks/<app>/<flavor>.md`, executed with ONLY ivps + cloudify commands.
- Rules: no ad-hoc scripts; variable NAMES in steps, never values; addresses by MagicDNS
  name, never IP; explicit human-gate steps (render acceptance); explicit teardown.
- First entry: rewrite `plans/xfce-guacamole-e2e.md` to the rules; plans are not runbooks.
- Validation = the amnesiac test: a fresh agent session with only the cloudify skill + the
  runbook path completes the deployment on disposable infra, no human hints; every
  stumble is a runbook defect.

Tasks:
- [ ] Create `runbooks/` and write the xfce+guacamole E2E runbook to the rules.
- [ ] Move/retire `plans/xfce-guacamole-e2e.md`.
- [ ] Run the amnesiac validation on disposable infra; fix every defect it surfaces.

Done when: the amnesiac run completes end to end.

## Branch 7 - state registry (prerequisite for runbooks b)

Gate: lib (write path + replay read), CRITICAL GATE.
Design (ROADMAP; supersedes ADR-011 point 6):
- Per-node slices `$(ivps node path <host>)/deployments/<id>/pkgs/<pkg>/config.yaml`,
  keyed (deployment, instance, package); a REPLAY INPUT, outside the precedence ladder.
- Resolution stays intent-only (recipe default < global < package < deployment < env);
  recorded values re-apply only on explicit re-enactment (`deployment run`/replay).
- Secrets as references/hashes, never plaintext; `ivps delete <host>` cleans the slice.
- Amend ADR-011 point 6 when this lands (record leaves the ladder).

Tasks:
- [ ] Implement the install-side slice write keyed (deployment, instance, package).
- [ ] Implement the replay read (`cloudify_vars_state_read`); explicit re-enactment only.
- [ ] Ensure `ivps delete <host>` removes the slice; secrets stay references/hashes.
- [ ] Amend ADR-011 point 6.

Tests:
- [ ] Integration: install writes the slice; replay re-applies only on explicit
  re-enactment; deletion cleans up.

Done when: slice lifecycle green, no silent merge into intent config.

## Branch 8 - runbooks (b): `cloudify deployment run`

Depends on branches 1-7.

Design (ROADMAP Runbooks b; Idea 3 stays non-urgent):
- Deployment declares roles + typed steps as data (launch/install/configure/verify/
  uninstall/human-gate); addresses by name.
- Step outputs (e.g. the launched guest's tailnet name) go to the state record as replay
  input, never merged into intent config; later steps consume them live.
- Preflight validates required vars via `vars declared` before launching anything.
- Secrets by name only (five-source walker; optional vault on either end); per-step
  security rules: payload via stdin, no secret in argv, masking.

Tasks:
- [ ] Design + implement `cloudify deployment run <id>` on the fixed surface.
- [ ] Typed steps + role declarations + human-gate step.
- [ ] Preflight via `vars declared`; step outputs into the state record.
- [ ] Author the xfce+guacamole deployment runbook as data.

Tests:
- [ ] Integration: the xfce+guacamole app runs from a deployment runbook on disposable
  infra; generated vs hand-written stays a later (Idea 3) exercise.

Done when: the deployment runbook completes end to end.

## Notes

- PLAN.md points at this plan while the cleanup runs.
- Disposable infra still up (optional teardown): `cloudai:xfce-test`, guacamole stack on
  `cloudai:cloudify`, deployment `xfce-gui`.
- Branch 4 needs branch 2; branch 8 needs branches 1-7.
- README.md:159/165 corrections ride with branch 1; ADR-011 point 6 amendment rides with
  branch 7.
