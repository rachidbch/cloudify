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
- [v] Branch 1b - vars CLI surface + declaration syntax + `vars declared` (merged c12783e)
- [v] Branch 1b-fix - R9: printing secrets is opt-in (mask default, `--reveal`, `--resolve`) (merged b0176ec)
- [v] Branch 2 - CLI actions: verify + uninstall (merged 48962d8)
- [v] Branch 3 - security: payload via stdin + skill Security section (merged 28f715c)
- [v] Branch 4 - guacamole 3-leg rewrite (merged 23af7c1)
- [v] Branch 5 - xfce alignment (merged 9ea2750)
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

Gate: router (`cloudify:491-563`), `lib/vars.sh` (declaration parse + write path),
`lib/remote.sh` (declared-file format). CRITICAL GATE.

### Gate tasks

- [x] Description artifact (2026-09-09): current surface traced below; repros `~/tmp/b1b/`.
- [x] Plan + non-breakage argument (this section).
- [x] Explicit consent (Rachid): approved 2026-09-09, R1b-7 option A (backend must exist at write time).

### What the code does today

- Router `vars` (`cloudify:491-539`): verbs set/delete|del/show/list|ls, no `unset`/`declared`;
  `set` consumes key then one of `--stdin` (`$(cat)`), `--file <path>` (`$(<file)`), or a
  positional value; trailing args silently ignored; every verb calls a
  `cloudify_vars_deployment_*` fn that reads only ambient `CLOUDIFY_DEPLOYMENT`.
- Ambient context is user-set only: `deployment use` prints `export CLOUDIFY_DEPLOYMENT=...`
  (`lib/deployments.sh:95-99`); ADR-011 point 4 (per-shell env, `unset` closes).
- Declaration parser (`lib/vars.sh:197-222`) accepts bare `^[A-Z_][A-Z0-9_]*$` only;
  `NAME=value`, `NAME=`, tabs, `\r`, extra spaces are dropped silently. Names feed the walker
  via a `name\tpkg` temp file (`vars.sh:211`) read by two loops (`remote.sh:167-178`); a
  declared name present in caller env is claimed/exported (`vars.sh:213-217`).
- Write path: `_cloudify_vars_file_set` (`vars.sh:162-177`) allows lowercase keys, stores
  multi-line as `@base64:`; deployment write needs ambient id; `list --json` trims with
  `xargs` (`vars.sh:292-293`); `show` prints raw and exits 1 on a missing key (pipefail, :313).
- Pinned: `deployments.bats` (aliases 21-31, ambient grep 152-157, --json 167-184,
  read/export 194-224, special chars 228-245), `remote-vars.bats` (bare declaration + warn +
  precedence), `vars.bats` (declaration registration 150-158, walker precedence 250-305).
  `shell-router.bats` has NO vars/deployment test: router arg parsing is untested.

### Invariants (must survive)

- I1b1 bare `NAME` still registers and still warns when nothing provides it.
- I1b2 declaration never exports a value; walker order env > deployment > package > global unchanged.
- I1b3 no scope flag = ambient; error text still contains `CLOUDIFY_DEPLOYMENT`.
- I1b4 legacy names `cloudify_vars_set|delete|list|show`, `_cloudify_deployment_read_vars` stay.
- I1b5 flat `KEY: value` + `@base64:` + 600/700 perms unchanged.
- I1b6 `--stdin`/`--file` keep secrets out of argv; `vars list` non-json stays raw; `--json` stays valid.
- I1b7 `vars show` prints the raw stored value (no resolution) for non-secret keys.
- I1b8 reserved-name warn+skip on read unchanged; reader exports stay redirect-only (no `$()`).

### Landmines (in scope flagged)

- L1b1 flag/value ambiguity: `vars set V --global` today stores `--global`; new flags change an
  accepted command line's meaning. IN SCOPE (R1b-1).
- L1b2 declaration default must never be exported: exporting `NAME=value` would become an
  env-strength source and beat global (`remote.sh:130-163`). IN SCOPE (R1b-4).
- L1b3 declared-file `name\tpkg` is consumed by two loops; a kind column corrupts `_dpkg`
  unless both change, and the warn must fire only for bare `NAME`. IN SCOPE (R1b-5).
- L1b4 `vars declared` must read the declaration mirror, never parse recipe `${VAR:-}`, and must
  not run the walker (exports + can `die`). IN SCOPE (R1b-3).
- L1b5 deployment fns read only ambient; explicit id needs an additive param. IN SCOPE (R1b-8).
- L1b6 `--json` xargs corruption (`"` breaks JSON, `\` stripped, comments become keys). IN SCOPE (R1b-6).
- L1b7 literal `@` stored raw, dies later at read/install. IN SCOPE (R1b-7).
- L1b8 name-regex asymmetry (write allows lowercase; global/pkg readers are uppercase-only). IN SCOPE (R1b-9).
- L1b9 `--stdin`/`--file` strip trailing newlines (`$(cat)`), losing PEM bytes. IN SCOPE (R1b-10).
- L1b10 `vars show <missing>` exits 1 via pipefail; status unpinned. IN SCOPE (R1b-11).

### Proposed resolutions

- R1b-1 Scope flags anywhere + `--` sentinel; mutually exclusive; `die` with a hint.
  `vars set V --global` becomes a scope (breaking, documented in HISTORY).
- R1b-2 One mutual-exclusion message; one ambient-unset message per verb containing
  `CLOUDIFY_DEPLOYMENT` + the `deployment use` hint.
- R1b-3 `vars declared <pkg>` default output = the declaration mirror, one line per var:
  `NAME` (required) / `NAME=value` (defaulted) / `NAME=` (optional); `--sources` appends
  `\t<source>` computed by read-only inspection (env, then deployment, package, global files,
  else `recipe-default`), never exporting. Unknown pkg -> die; no `.remote-vars` ->
  `(no declared vars)`. Secret-looking names (`PASSWORD|TOKEN|SECRET|KEY`) mask the shown
  default as `***`.
- R1b-4 Declaration `NAME=value` / `NAME=` are documentation mirrors: parsed for display and
  kind only, never exported; `${VAR:-}` stays runtime truth. Warn fires only for `required`
  with no value from any source.
- R1b-5 Internal declared-file becomes `name\tpkg\tkind` (kind = required|defaulted|optional);
  both `remote.sh` loops read the third field; warn gated on `required`.
- R1b-6 `--json` built in pure bash with `_cloudify_vars_json_escape` (`\` and `"` escaped,
  control chars dropped) and comment/blank lines skipped.
- R1b-7 Write-time reference validation: accept `@@...` (literal), `@base64:...`, and
  `@<backend>:<locator>` whose backend function exists; else die with the `@@` hint.
- R1b-8 Add an optional trailing id arg to the four deployment fns (default ambient); router
  passes `--deployment <id>`. Aliases unchanged.
- R1b-9 Write-time key validation: uppercase-only for `--global`/`--pkg` (their readers are
  uppercase-only); the deployment store stays permissive (back-compat).
- R1b-10 Preserve exact bytes for `--stdin`/`--file` (`v=$(cat; printf x); v="${v%x}"`).
- R1b-11 `vars show <missing>` prints nothing and exits 0.

### Tasks

- [v] T1 declaration parser: accept `NAME`, `NAME=value`, `NAME=`; emit `name\tpkg\tkind`;
  never export the mirror (I1b1/I1b2, R1b-4).
- [v] T2 `remote.sh`: read the kind column in both declared-file loops; warn only for `required` (R1b-5).
- [v] T3 router: `vars` scope flags anywhere + `--` sentinel, mutual exclusion, ambient fallback
  hint (R1b-1/2); `unset` alias of delete.
- [v] T4 deployment fns: optional trailing id arg; router plumbing (R1b-8).
- [v] T5 `vars set --stdin/--file` byte preservation + write-time `@` validation + uppercase key
  guard (R1b-7/9/10).
- [v] T6 `vars declared <pkg>` with `--sources` + masking (R1b-3).
- [v] T7 `--json` pure-bash escaping (R1b-6); `show` missing key exit 0 (R1b-11).
- [v] T8 skill: pkg-writing var standard + the declaration/recipe sync rule.
- [v] R9 (re-anchored): printing secrets is opt-in. `vars show`/`list` mask secret-looking values by
  default, `--reveal` prints them, `--resolve` decodes a reference. Masking lives in the router, so
  the library functions stay raw and the pinned exact-value tests hold. Shipped as branch 1b-fix.

### Tests

- [v] Unit: declaration parse matrix (three kinds, tabs, CRLF, back-compat bare) + warn only for required.
- [v] Unit: router scope flags (mutual exclusion, ambient fallback, `--` sentinel, flag-looking value).
- [v] Unit: `vars declared` three kinds, `--sources`, masking, unknown pkg.
- [v] Unit: write-time `@` validation (accept `@@`, `@base64:`, registered backend; reject unknown with hint).
- [v] Unit: `--json` with `"`/`\`/spaces/comments; `show` missing key exit 0; `--stdin` trailing-newline preservation.
- [v] Router subprocess: scoped set/show/list, stdin bytes, `@` reject, `declared` (shell-router gap closed for vars).
- [v] Regression: `deployments.bats`, `remote-vars.bats` unmodified and green; `vars.bats` one test
  precondition updated (see outcome).

### Done when / merge gate

- [v] All tasks `[v]`; unit suite green; `deployments.bats`/`remote-vars.bats` unmodified.
- [v] Merge gate: blast-radius integration (`package-remote-vars.bats`) green + a real CLI smoke
  of `vars declared` and a scoped `vars set/show` on `cloudai:cloudify`.

### Branch 1b outcome (2026-09-09)

- Merged to master as `c12783e` (--no-ff) after the e2e merge gate.
- Landed: declaration kinds (`NAME`/`NAME=value`/`NAME=`), declared-file kind column,
  scope flags + `--` sentinel + `unset`, optional deployment id, write-time `@` validation
  (option A), uppercase key guard for global/pkg, byte-preserving `--stdin`/`--file`,
  `vars declared [--sources]` with masking, pure-bash `--json`, `show` missing key exit 0,
  router help text, skill var standard.
- Tests: new `tests/unit/vars-cli.bats` (22); full unit suite 367 green; shellcheck clean.
- Merge gate: `package-remote-vars.bats` PASSED; CLI smoke on `cloudai:cloudify` green
  (`vars declared guacamole --sources`, scoped set/show/list, stdin secret, `@` reject).
- Deviation (approved R1b-7): an unknown backend now dies at write time, so the branch-1 test
  "walker: an unresolvable file-store reference dies" can no longer set it up via
  `cloudify_vars_pkg_write`; it now writes the file directly, preserving the read-time-die
  assertion. `deployments.bats`/`remote-vars.bats` untouched.
- Open: none for 1b; R9 shipped as branch 1b-fix (secrets opt-in: mask default, `--reveal`, `--resolve`).

## Branch 2 - CLI actions: verify + uninstall

Gate (widened): router + `lib/packages.sh` + `lib/package-api.sh` + `lib/remote.sh`
(walker token set for uninstall var forwarding).

### Gate tasks

- [x] Description artifact (2026-09-09): current surface traced below; repros `~/tmp/b2/`.
- [x] Plan + non-breakage argument (this section).
- [x] Explicit consent (Rachid): approved 2026-09-09 (Q2 accepted, verify-load fix rides with Branch 2).

### What the code does today

- Two disjoint word tables: `_cloudify_is_reserved` (`cloudify:180-194`) and
  `_cloudify_is_action` (`cloudify:197-203`). `verify`, `remove`, `rem`, `r` are in neither.
- `--on <host>` consumes words until a reserved/action/flag word (`cloudify:599-626`), so
  `cloudify --on host verify pkg` swallows `verify` as a host and dies
  `No packages found for hosts: ...` (`cloudify:625`).
- Action block (`cloudify:627-661`): `packages` carries `--<action>`; a second action word
  dispatches the first. A flag after the verb is treated as a package.
- Local dispatch `_cloudify_execute_package_action` (`cloudify:206-259`): install runs
  `@default` then backgrounds the action; configure calls the walker then
  `cloudify_configure_package`; uninstall backgrounds `cloudify_uninstall_package` with no
  walker call (`:251-256`). Remote ships `--<action> <pkgs>` (`:309-310`).
- `cloudify_uninstall_package` and `cloudify_uninstall_default_packages` are stubs
  (`lib/packages.sh:275-282`); `remove|rem|r` are documented but unimplemented.
- Phase sourcing: `_cloudify_source_pkg_phases` sources `init.sh` + `configure.sh`
  (`lib/package-api.sh:379-391`), used only by `pkg_depends`; `cloudify_configure_package`
  sources `configure.sh` separately (`lib/packages.sh:180-208`). No uninstall resolver, no
  `uninstall.sh` in any recipe. Recipes run with errexit suspended (ADR-018).
- Verify: `_cloudify_run_verify` (`lib/package-api.sh:335-377`) no-op rc 0 without verify.sh,
  loads `pkgs/<pkg>.yaml` in overwrite mode (`:345`), retries with `PKG_VERIFY_TIMEOUT`.
  Local `cloudify verify` is a top-level case (`cloudify:480-490`) that ignores `--on`.
  Remote verify-only = `--verify install <pkg>` (`cloudify:271-292`), ships
  `cloudify verify <pkgs>` to the host. Walker treats only install/configure as install-like
  (`lib/remote.sh:113-116`), so verify and uninstall forward the global source only.
- Pinned: `shell-router.bats:243-280` (local verify subcommand), `package-api.bats:465-578`
  (verify hook, incl. `:528-549` pkg-yaml load), `install-run-split.bats`,
  `integration/package-install-run-split.bats`, and `vars.bats:352-360` which pins
  verify = global-only forwarding (I11).

### Invariants

- I2-1 `--on` before the verb; host block word consumption unchanged.
- I2-2 reserved and action tables stay distinct; adding an action must not shadow a host word.
- I2-3 `packages` keeps the `--<action>` prefix; local strips it, remote ships it.
- I2-4 `--on localhost` stays local.
- I2-5 background model + OK/FAILED reporting + exit 1 on any failure.
- I2-6 `CLOUDIFY_FORCE` only for explicit install; deps unset FORCE/CLEAR_DATA.
- I2-7 verify hook gated by `CLOUDIFY_NO_VERIFY`, runs after install and configure.
- I2-8 verify no-op rc 0 without verify.sh/recipe.
- I2-9 forwarding: install/configure (+uninstall per R2-7) walk the sources; verify stays
  global-only remotely (I11) and pkg-yaml locally.
- I2-10 ADR-008 back-compat: init-only packages install unchanged.
- I2-11 uninstall with no leg fails non-zero and changes nothing.
- I2-12 configure on a non-split package still errors `no configure.sh`.

### Landmines (in scope flagged)

- L2-1 top-level `verify)` case shadows an action-table `verify` and runs locally (proved).
  IN SCOPE (R2-4).
- L2-2 a package literally named `verify` becomes un-installable (proved). IN SCOPE (R2-8).
- L2-3 treating `verify` as install-like breaks `vars.bats:352-360`. Avoided (R2-2).
- L2-4 empty-package guard (`cloudify:268`) omits `--uninstall`/`--verify`: empty dispatch
  reaches ssh/recipes. IN SCOPE (R2-3).
- L2-5 local uninstall skips the walker; remote uninstall is global-only, so a teardown leg
  needing package/deployment vars fails. IN SCOPE (R2-7).
- L2-6 shipping `--verify <pkgs>` to the host hits `Unknown argument`; must send
  `verify <pkgs>`. IN SCOPE (R2-1).
- L2-7 absent-leg `die` aborts sibling packages in a multi-package uninstall. IN SCOPE (R2-6).
- L2-8 pre-existing: verify loads the pkg yaml in overwrite mode and clobbers the walker value
  (proved). IN SCOPE (R2-12).
- L2-9 a naive "not a package" parser check breaks install's native apt fallback. IN SCOPE (R2-3).
- L2-10 `verify <unknown>` and `<no verify.sh>` both exit 0 silently. IN SCOPE (R2-5).
- L2-11 alias collisions (`v`, host/package named verify). IN SCOPE (R2-8).
- L2-12 ADR-018 errexit suspension in a sourced uninstall leg: bare failures continue. IN SCOPE
  (uninstall legs use explicit `|| die` + postconditions, house style).

### Proposed resolutions

- R2-1 `verify` joins the action table and dispatch; remove the top-level `verify)` case so
  there is one path; remote ships `verify <pkgs>`; `--verify install` maps to the action.
- R2-2 verify var forwarding unchanged: global-only remotely (I11, `vars.bats:352-360`),
  pkg-yaml locally. Document the asymmetry.
- R2-3 Parser errors: empty package list, a flag where a package is expected, or an
  action/reserved word after the verb dies clearly. `verify`/`uninstall` require a known
  cloudify package (`Not a cloudify package: X`); `install` keeps the native apt fallback.
  The empty-package guard covers `--uninstall`/`--verify`.
- R2-4 Single verify path (no top-level shadow).
- R2-5 Known package without `verify.sh` -> no-op rc 0 (deep verify optional); unknown name -> die.
- R2-6 Uninstall collects per-package failures and exits non-zero if any; siblings still run.
- R2-7 Uninstall forwards package/deployment/global vars: add uninstall tokens to the walker's
  install-like check (`lib/remote.sh:113-116`) and call the walker on the local uninstall path.
- R2-8 No `v` alias; `verify` is a reserved action word (documented, like install/configure).
- R2-9 `--no-verify` is ignored when the action is `verify` (explicit verify wins).
- R2-10 Uninstall never calls `pkg_depends` and never runs verify; deps untouched.
- R2-11 Docs: README:44, router help, and the skill's uninstall-stub line.
- R2-12 Fix L2-8: `_cloudify_run_verify` loads the pkg yaml through a temporary claim ledger in
  no-clobber mode, so walker/caller values survive; `package-api.bats:528-549` stays green
  (its var is unset before the load).

### Tasks

- [v] T1 verify action: action table + dispatch, remove the top-level case, remote `verify <pkgs>`,
  `--verify install` alias, `--no-verify` ignored for verify (R2-1/4/9).
  Note: pinned `shell-router.bats` pins the top-level verify messages/rc, so the action path
  reproduces `Missing package` and the same exit codes; those tests stay unmodified and green.
- [v] T2 parser + empty-package guard for verify/uninstall; known-package check; install fallback
  untouched (R2-3/5).
- [v] T3 uninstall action: real `cloudify_uninstall_package`, `cloudify_package_uninstall_path`,
  absent leg = clear error + non-zero + no action, per-package failure collection, deps untouched,
  verify not run (R2-6/10).
- [v] T4 uninstall var forwarding: walker install-like tokens + local uninstall walker call (R2-7).
- [v] T5 verify yaml load no-clobber via a temp ledger (R2-12).
- [v] T6 docs: README, router help, skill; documented `remove|rem|r` aliases implemented (R2-11).

### Tests

- [v] Unit: `verify` action routing local and `--on`; `--verify install` alias; `--no-verify` ignored.
- [v] Unit: parser errors (empty, flag, non-package) + install apt fallback intact.
- [v] Unit: uninstall resolution, absent leg error + no action, multi-package failure collection.
- [v] Unit: uninstall forwards package/deployment vars; verify stays global-only (pinned).
- [v] Unit: verify keeps a walker-set value over the pkg yaml (L2-8 fix).
- [v] Integration: fixture package with `uninstall.sh` removes its markers; absent leg errors;
  deps untouched; remote verify action; existing split/verify tests green.

### Done when / merge gate

- [v] All tasks `[v]`; unit suite green; pinned split/verify tests unmodified.
- [v] Merge gate: `package-uninstall.bats` + `package-install-run-split.bats` PASSED (the remote
  verify action and uninstall are exercised end to end there, so they are the CLI smoke).

### Branch 2 outcome (2026-09-09)

- Merged to master as `48962d8` (--no-ff) after the e2e merge gate.
- Landed: `verify` first-class action (local + `--on`, remote ships `verify <pkgs>`, alias kept,
  top-level case removed); parser errors (empty list, flag after the action, non-package) and the
  empty-package guard; real `uninstall` action (`cloudify_package_uninstall_path`, optional
  `uninstall.sh`, absent leg = clear error + no action, per-package failure collection, deps
  untouched, verify not run); uninstall forwards the same resolved vars as install/configure;
  `remove|rem|r` aliases; the verify yaml load is fill-only so a walker-resolved parent override
  survives (constraint a); README + skill updated; lint glob covers `pkg/*/uninstall.sh`.
- Tests: new `tests/unit/actions.bats`, `tests/unit/uninstall.bats`, `tests/unit/verify-vars.bats`,
  `tests/integration/package-uninstall.bats`, new fixture `pkg/fixture-uninstall`; full unit suite
  386 green; shellcheck clean; pinned `shell-router.bats`/`package-api.bats`/`split` tests
  unmodified and green.
- Flake observed once: the first `package-uninstall` run right after a snapshot restore failed,
  then passed on re-run and on the canonical two-file gate. Likely container warm-up; watch it,
  add a readiness probe to the runner if it recurs.
- Design note (non-urgent candidate): resolution could become a step that always precedes a phase
  (verify-only included), removing the source read from verify entirely. Not needed for the bug.

## Branch 3 - security: payload via stdin + skill Security section

Gate: `lib/remote.sh`.

### Gate tasks

- [x] Description artifact (2026-09-09): read-only trace of payload build/transport, exit-code
  capture, TTY/stdin ownership, secret exposure points, pinned tests (below).
- [x] Plan + non-breakage argument (this section).
- [x] Explicit consent (Rachid): approved 2026-09-09 ("Continue").

### What the code does today

- Payload build (`lib/remote.sh:279-302`): `declare -f cloudify_remote_payload_template` body,
  `_CLOUDIFY_PKG_EXPORTS_` placeholder, `envsubst` allow-list, single-quote baking, appended
  `; cloudify $*` (`:291`), DEBUG dump masked for `PWD|PASSWORD|SECRET|TOKEN|KEY` (`:297-302`).
- Transport (`lib/remote.sh:312-317`): the payload is the **last argv** of
  `ssh -o ... "$CLOUDIFY_REMOTE_USER@$host" "$cloudify_remote_payload"`, piped through two
  `sed` + `tee`. No sshpass; key/MagicSSH auth. No `-t` on this path (`shell` is separate).
- The template ends `exec > >(tee -a "$CLOUDIFY_LOG_FILE") 2>&1 </dev/null` (`lib/remote.sh:84`),
  deliberately detaching stdin (comment: the old hang was `cat -` blocking on stdin).
- Exit code: `set -Eeuo pipefail` makes the ssh pipeline status the last non-zero; captured into
  `$CLOUDIFY_TMP/<host>.exit` (`lib/remote.sh:277`, `:318`); the wait loop prints OK/FAILED.
- Secrets today sit in operator argv and host argv (the whole payload string). Logs capture
  command output; the DEBUG dump is masked.
- Pinned: `tests/unit/remote-vars.bats:39-47` stubs `ssh()` and reads the **last argv** as the
  payload; `tests/unit/remote.bats` asserts template body contents (transport-agnostic);
  `tests/integration/package-install-run-split.bats` exercises the real path.

### Proven landmine (empirical)

- `printf 'echo ONE\nexec </dev/null\necho TWO\n' | bash -s` prints `ONE` only; a 10k-line
  script prints nothing after the `exec`. `bash -s` reads the script from stdin, so a global
  `exec </dev/null` truncates it. The naive `ssh host 'bash -s' < payload` would drop
  `cloudify init` and the appended `cloudify $*` (silent no-op installs). Repro `~/tmp/b3/`.
- Per-command stdin redirects are safe: `bash -s` keeps reading the script while a command's
  stdin is `/dev/null` (verified).

### Invariants

- I3-1 exports remain the value channel; the payload's `export` lines are unchanged (I1).
- I3-2 envsubst allow-list + single-quote baking unchanged (I6, I8).
- I3-3 the remote re-invocation `cloudify $*` still runs and its exit code is what the operator
  reports (OK/FAILED, `.exit` file).
- I3-4 the DEBUG dump stays masked.
- I3-5 localhost path unchanged (it never sshs; `lib/remote.sh:200-208`).
- I3-6 `cloudify shell` and its `-t` handling are untouched.
- I3-7 the host still holds the plaintext in its environment (fundamental limit, documented).

### Proposed resolutions

- R3-1 Transport: write the payload to a local `0600` temp file under `$CLOUDIFY_TMP` and run
  `ssh ... "$CLOUDIFY_REMOTE_USER@$host" 'bash -s' < "$payload_file"`. No secret in operator or
  host argv. A file redirect (not a pipe) avoids a SIGPIPE race that a pipe would introduce with
  `pipefail`. Remove the file after the ssh returns.
- R3-2 Template stdin policy: drop the global `</dev/null` from the `exec` line; add `</dev/null`
  to every template command that can consume stdin: the bootstrap `bash -c "$(curl ...)"`,
  `cloudify init`, and the appended `; cloudify $* </dev/null`. Proven shape.
- R3-3 Exit code: unchanged mechanism (ssh rc through `pipefail` into `.exit`); add a test that a
  failing remote command still yields FAILED.
- R3-4 Pinned-test mechanism: `remote-vars.bats:39-47` must read the stub's **stdin** instead of
  its last argv. Contract (payload contains `K3S_TOKEN='token-A'`) is unchanged; only the capture
  mechanism changes. Flagged because it edits a pinned test file.
- R3-5 Skill Security section: stdin payload; references in cloudify state; masking; 0600; no
  secrets in logs; the two vault models (operator-side default, host-side); the fundamental limit
  that the host must hold the plaintext.
- R3-6 MagicDNS names never IPs; address-shaped values derived at run time (trap 6); validate once
  that guacd resolves MagicDNS inside the compose network (rides Branch 4's stack, recorded here).

### Tasks

- [v] T1 transport to `bash -s` with a `0600` local payload file; remove it after (R3-1).
- [v] T2 template stdin policy: per-command `</dev/null` (R3-2).
- [v] T3 update the `ssh()` stub in `remote-vars.bats` to read stdin (R3-4).
- [v] T4 skill Security section + MagicDNS rule (R3-5/6).

### Tests

- [v] Unit: stub `ssh` reads stdin; assert the payload carries `K3S_TOKEN='token-A'` and the
  remote command is `bash -s` with no secret in argv.
- [v] Unit: a failing remote command still writes a non-zero `.exit`.
- [v] Unit: template contains no global `exec ... </dev/null`; `cloudify init` and the appended
  command redirect stdin.
- [v] Integration: `package-uninstall.bats` + `package-install-run-split.bats` green (the two-host
  file was deleted as redundant).

### Done when / merge gate

- [v] All tasks `[v]`; unit suite green; pinned `remote-vars.bats` mechanism updated and green.
- [v] Merge gate: `package-uninstall.bats` + `package-install-run-split.bats` PASSED; secret-absence
  proved by `tests/unit/remote-stdin.bats` (stub ssh: payload on stdin, argv is `bash -s`).

### Branch 3 outcome (2026-09-09)

- Merged to master as `28f715c` (--no-ff) after the e2e merge gate.
- Landed: stdin payload transport (0600 local temp file, `ssh host 'bash -s' < file`), per-command
  stdin redirects (the global `exec </dev/null` truncates `bash -s`, proven), `remote-stdin.bats`,
  `remote-vars.bats` stub reads stdin, skill Security section.
- Test output standard: `tests/helpers/report.bash` (fd 9 live), runner streams `bats -T
  --show-output-of-passing-tests | tee results/<name>.tap` + plan; rubrics in `package-uninstall`.
- Deleted `package-remote-vars.bats` + `pkg/fixture-env` as redundant.
- Evidence: unit 389/389 rc 0; shellcheck clean; integration `package-uninstall` 3/3 +
  `package-install-run-split` 8/8, streamed live from the `.tap`.

### Deleted as redundant (2026-09-09)

- `tests/integration/package-remote-vars.bats` and `pkg/fixture-env`: the parallel race guard is
  the unit test `remote-vars.bats` (parallel collections keep their own env), single-host E2E
  forwarding is `package-install-run-split.bats:64-67`, payload baking is `remote-vars.bats:39-47`.
  The second container cost ~50s and a readiness flake for no marginal coverage.

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
- [v] Rewrite `pkg/guacamole/{install,configure,uninstall}.sh` per the 3-leg contract.
- [v] Sync `verify.sh`: admin fallback `rbc` -> `guacadmin`; re-check it against the new
  schema-init and DB-converge paths (it reads on-disk `.env` state).
- [v] Decide whether to declare `CLOUDIFY_GUACAMOLE_ADMIN_USER` in `.remote-vars`: declared.
- [v] Change the admin default to `guacadmin`.
- [v] Decide + implement the schema-init mechanism: kept docker cp + psql (initdb.d evaluated,
  not adopted: the marker + partial-init detection already work, and initdb.d needs an image
  binary assumption for the healthcheck).
- [v] Update `pkg/guacamole/README.md` + declaration.

Tests:
- [v] Integration: install, configure (incl. changed DB password converges), uninstall
  removes volumes, FORCE reinstall preserves data. 7/7 on `cloudai:cloudify`.

### Branch 4 outcome (2026-09-09)

- Merged to master as `23af7c1` (--no-ff) after the e2e merge gate (7/7).
- Landed: install provisions (create-if-absent `.env`/compose, `up -d --wait postgres guacd`,
  one-time schema init); configure configures (rewrite, `up -d --wait`, converge the postgres role
  password via the container local socket, converge the admin hash + rename, upsert the RDP
  connection); new `uninstall.sh` (`down -v` then remove the project dir); admin default
  `guacadmin`; `.remote-vars` declares `CLOUDIFY_GUACAMOLE_ADMIN_USER`; README + verify synced.
- Tests: `package-guacamole.bats` rewritten to the report standard (rubric/subrubric/step, fd 9
  live, `setup_file` readiness wait, base URL derived from the deployed `.env`). 7/7 green.
- Infra fix: the `itest-base` snapshot carried a stale `guacamole_guacamole_pgdata` volume with
  the old `rbc` database, which made the recipe correctly refuse to reseed. Removed it and
  re-baked `itest-base`.
- Note: the operator's `~/.config/cloudify/pkgs/guacamole.yaml` supplies `CLOUDIFY_GUACAMOLE_BIND`
  (tailnet IP); the test derives the base URL instead of assuming loopback. Test hermeticity vs
  the operator config is a known gap.
- Note: a FORCE reinstall recreates the postgres container (compose config drift), which keeps the
  named volume; the test asserts data survival (admin login + connection), not the container id.

## Branch 5 - xfce alignment

Gate: recipe only.

Design: declaration syntax per the pkg-writing standard; neutral defaults; keep
install/configure; optional `uninstall.sh` (remove packages/user only with explicit
intent; never the home).

Tasks:
- [v] Align `pkg/xfce` declaration + defaults with the standard.
- [v] Add the optional `uninstall.sh` with the explicit-intent guard.
- [v] Update `pkg/xfce/README.md`.

Tests:
- [v] Integration: `package-xfce.bats` green (7/7) + `vars declared xfce` output.

### Branch 5 outcome (2026-09-09)

- Merged to master as `9ea2750` (--no-ff) after the e2e merge gate (7/7).
- Landed: `.remote-vars` now uses the three-kind declaration (`CLOUDIFY_XFCE_USER=gui`,
  `CLOUDIFY_XFCE_USER_PASSWORD=`, `CLOUDIFY_XFCE_SESSION=startxfce4`,
  `CLOUDIFY_XFCE_RDP_PORT=3389`, `CLOUDIFY_XFCE_INSTALL_CHROME=true`,
  `CLOUDIFY_XFCE_UNINSTALL_USER=`); new `uninstall.sh` (purge packages + disable/remove xrdp,
  delete the state file; account removed only with `CLOUDIFY_XFCE_UNINSTALL_USER=true`, home never
  removed); README updated; `package-xfce.bats` rewritten to the report standard (rubric/subrubric/
  step, fd 9 live, `setup_file` readiness) with uninstall coverage.
- Evidence: L0 shellcheck + `bash -n` clean; `cloudify vars declared xfce` prints the six kinds;
  L1 proof of the uninstall leg on the container (default keeps the account, explicit removes it,
  home preserved); harness 7/7 green.
- Findings: `apt-get purge` can fail on a concurrent `unattended-upgrades` dpkg lock; the leg now
  passes `-o DPkg::Lock::Timeout=300` (shadow untouched). The shadow `sudo` requires a password;
  `--on localhost` probes must set `CLOUDIFY_LOCAL_PWD` or they die silently.
- Environment: one gate run was lost to a ~64-minute host suspend (ssh dropped; the install
  succeeded on the host and all other tests passed). Re-run green.

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
