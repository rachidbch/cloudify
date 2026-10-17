# State convergence

Status: approved for feature-branch implementation; live-state mutation remains gated.
Date: 2026-10-17.
Tracking: [State convergence (#17)](https://github.com/rachidbch/cloudify/issues/17).

## Outcome and authority

Implement Inventory owns current state (ADR-036), Environment-only secrets (ADR-037), Defaults ladder (ADR-038), Boolean failure marker (ADR-039), Secret markers with suffixes (ADR-042), and Unnamed deployment matching (ADR-031).
The settled contract is in `REDESIGN.md`; this plan applies the final 2026-10-17 decisions, not superseded clauses in earlier ADRs or stale design paragraphs.
Do not reopen the settled design or implement Host origin and continuity (ADR-028).

A fresh controller with recipes/runbooks, synchronized ivps inventory, and caller-supplied secret environment variables must continue current deployments without local manifests, events, or run snapshots.
Files hold defaults; the environment supplies values; inventory records applied values.

## Approval gates

- [x] Plan approval (G1): Rachid approved this plan, including the test-transport prerequisite and explicit existing-record conversion.
- [x] Schema approval (G2): Rachid approved changing `schemas/v1/` in place, retaining `schema_version: 1`, and updating its validator and fixtures rather than introducing v2 (Schema v1 evolution, ADR-040).
  Recommendation: in-place v1 because no external consumers are reported; confirm that assumption before changing schemas.
  This is an incompatible record change even with the same schema version; back up and explicitly convert existing records, never silently accept both shapes at runtime.
- [x] Fragile-contract approval (G3): Rachid authorized the named declaration, ladder, classification, and seeding changes plus their pinning tests.
  Authorize payload-golden regeneration only for explained export differences caused by these approved changes, not blanket acceptance of arbitrary byte changes.
  All unrelated payload and shadow goldens must stay byte-identical.
- [ ] Live-state approval (G4): approve each per-application live conversion before it runs - one application at a time, backup before every write, verify before the next (per-application live conversion, ADR-043); deleting octop's deployment defaults file stays a separately surfaced decision.
  Plan approval does not authorize any production mutation, adoption, restart, or credential change.

Record each approval here before crossing its gate.
Any newly discovered contract change needs a new explicit go.

## Contract to prove

- Classification comes from `secret NAME` markers or exact uppercase suffixes `_PASSWORD`, `_SECRET`, `_TOKEN`, `_KEY`, `_PWD` (ADR-042); either qualifying mapping side protects the shared input and all aliases.
- Complete removal of name-based recognition is a deferred roadmap item, not part of this implementation.
- Secret values come only from this invocation's environment after names-only mappings; no provider lookup, digest demand, secret preflight, or snapshot-secret restoration.
- Missing secrets may fail recipe/verify hooks; diagnostics name the original runbook input through `map:`, or the package variable for a bare dispatch.
- Inventory, events, and safe snapshots record secret names as `****`, never values, digests, provider locations, or `redacted` flags.
- The guard compares only the package's own declared non-secret recorded values; it never compares `****` entries or refuses sharing solely because secrets exist.
- `@base64:` is file-store multiline transport only; ordinary decoded scalars remain ordinary inventory values.
- Lean package records contain root applied scalars plus `target`, `user_forced`, optional `failed: true`, `version`, `revision`, and the approved schema-version field.
- Identities derive from the inventory path and parent identity records; `_direct` records use target `direct`.
- Records have no `applied` wrapper, `health`, `last_attempt`, per-value source metadata, or digest fields; multiline settings are native JSON strings.
- Failed operations preserve confirmed settings and set `failed: true`; only successful install/reconfigure clears it, never passing verify.
- Defaults resolve recipe < global < package < application < application-flavor < caller environment; a present empty entry remains a claim.
- Reconfigure resolves environment > applied user-forced values > file defaults > recipe fallback; non-forced applied values never seed.
- `deployment unset` removes names from `user_forced`, retaining host locks and event-backed updates.
- Replay without `--at` converges inventory; `--at <run>` restores that YAML snapshot's ordinary settings; secrets always come from the current environment.
- Unnamed application runs match proven-identical bindings, ordinary scalars, and secret-name sets; with no deployments generate the first name, otherwise refuse unmatched or ambiguous candidates and name them.
- Manifest reads rebuild missing, corrupt, or revision-stale caches from inventory, never requiring history.
- Rebuilt status is `failed` when a failure marker exists, otherwise `installed` when settings exist, otherwise no word; adopted records rebuild to `installed`.
- Local observation words remain `adopted|installed|reconfigured|verified|failed`; runtime `degraded` is retired.

## Verification and non-breakage

Use `cloudai:cloudify` only, with one plain `ssh root@${CLOUDIFY_TEST_TARGET:-cloudify}` session streaming the tree, running Bats remotely, and returning the SSH exit status.
Load `headless-ssh` before SSH and `cloudify-pkg-dev` before editing declarations; use cloudify/ivps for lifecycle work, never direct Incus without consent.
Do not use legacy `:container` tasks, reset snapshots mid-ladder, remove/reaccept host keys, erase earlier results, or heal an unhealthy test environment.
Stop and report host-key churn, missing prerequisites, probe timeouts, or lost results with raw evidence and a proposed remedy.
Read dispatch logs and TAP raw; no filtering or discarded dispatch output.
Choose timeouts at three times the measured or estimated duration; do not kill a slow mutation without proving no progress.

For each slice: one focused failing test on the target, minimum implementation, passing test, then refactor.
Prove behavior with target-side drivers/manual runs before acceptance; Bats is the completion gate, not the debugger.
Every tool-code slice closes with full `task test-unit`, `task gate`, `task lint`, and `task test-canary`; declaration-only follow-ups also run affected package tests.
Do not repeat full package sweeps per slice; reserve a full sweep for the final milestone and agreed package scope.
Push committed code before GitHub-backed dispatches and run them with `CLOUDIFY_FORCE_UPDATE=true`.
Keep results outside the dispatched tracked tree or excluded from executed-code attestation; retain raw evidence and the command exit status.
Each run retains `results/<suite>.<unique>/report.tap`, with `results/<suite>.tap` pointing to the latest report.
The canary runs all seven real Guacamole lifecycle checks locally inside cloudify; payload/remote-dispatch/inventory claims require their separate transport, state, and batch-exit E2E gates (Dedicated-host canary, ADR-041).

Fragile invariants touched: one resolution per dispatch; first-claim and empty-value semantics; declared-name/mapping gate; 0600 context ownership and cleanup; explicit sorted envsubst allow-list; single-quoted values; stdin-only payload transport; live unfiltered output.
Ladder order and secret classification change only under Fragile-contract approval (G3).
Shadow recursion/password handling, stdin transport, log streaming, and unrelated payload bytes do not change.
Run `task gate` before and after fragile edits and inspect golden diffs individually.

## Ordered implementation

### Baseline and prerequisites (S0)

- [x] Created `feat/state-convergence` before implementation; tracking issue is State convergence (#17).
- [x] Reconciled stale `REDESIGN.md` clauses to the settled contract: secret preflight/open questions, sharing refusal, old record fields, failure semantics, replay source, and obsolete deployment-input wording.
  Synchronize relevant roadmap entries; never rewrite historical ADR bodies or harness instructions without consent.
- [x] Replaced the legacy canary path with one plain Tailscale SSH session running Bats inside cloudify, without Incus, snapshot resets, host-key changes, or self-SSH (Dedicated-host canary, ADR-041).
  Preserved all seven stack lifecycle checks; remote payload and state behavior retain separate gates rather than being claimed by this local canary.
  Seven focused checks pass: VERSION and spaced arguments, exact SSH/Bats failure exits, extraction failure stopping Bats, retained reports, producer failure before SSH, report-write errors, and Docker failures before mutation.
  Technical review used one review/fix pass and one verification pass: PASS.
  The dedicated host was explicitly cleaned before restarting the ladder; no environment healing is part of a test run.
- [x] Fresh unmodified-runtime baseline completed on pushed HEAD `a53cf76`: full unit 804/0, fragile gate 144/0 before and after the comment-only annotation, full lint exit 0, and real canary 7/0.
  Every task and the serial owner exited 0; independent raw TAP checks found no skips, missing/duplicate results, or bailouts.
  Reports: `results/unit.PQgTrWrD/report.tap`, `results/gate.dZVKpqXT/report.tap` (before), `results/gate.Hl6OeCOB/report.tap` (after), `results/canary.q5GLaZbG/report.tap`.
  The payload remained byte-identical; no golden regeneration, environment healing, or acceptance retry occurred.
- [x] Audited existing package-record producers/readers and conversion inputs: worker and state apply, context seeding/projection, adoption, matching, unset/display/delete, replay, registry staging, and migration reporting.
  All 11 package declaration files were checked: 43 declarations, 41 distinct names, no exact collisions with schema_version/target/user_forced/failed/version/revision.
  No schema filename/URL references were found in selected code paths of ivps, its provider/skeleton, cfy, or clibash; this is bounded evidence, not proof of no external consumers.
  The current active-claim guard hook is reserved and matching is not wired; the approved guard and matching behavior must land during Unnamed matching (S7).

### Marker sweep and suffix fallback (S1)

- [x] Audited all 11 `pkg/*/.remote-vars` and six shipped runbooks; added 11 missing package marker sites plus runbook `secret RDP_PASSWORD`, retaining affine's existing marker.
- [x] Added `secret NAME` input parsing without changing the bare-name API; names-only `CLOUDIFY_APP_SECRET_INPUTS` metadata crosses child processes and resets per runbook.
- [x] Shared the exact suffix predicate and marker reader across context/display; marked default mirrors and stored package-variable values are masked unless explicitly revealed.
- [x] Focused contracts prove suffix boundaries, explicit exceptions, fan-out/cycles, either mapping side, dependency markers, stronger caller overrides, child-process propagation, instance-key refusal, and unchanged declaration kinds/raw/source fields.
  Connected-name propagation is O(names + mappings), with no second value-source walk; file stores cannot replace the mapping controls.
- [x] Bumped VERSION to 0.4.0 and verified CLI file output plus the event writer's test override.
- [x] Used focused red/green contracts on cloudify; combined S1-focused run passed 28/28, plus the active-map display regression and affected display checks passed 3/3, with scoped shellcheck and shell syntax clean.
  Full unit/gate/canary remain slice-exit gates, never debugging loops.
  Fragile invariants: one resolution; unchanged three-field candidate and four-field raw/provenance records; declared-destination gate; caller precedence; 0600 context ownership/cleanup; payload export names/order/bytes and stdin transport unchanged.
  S0's final gate is the fresh before-edit baseline; run the gate again at S1 exit without regenerating payload goldens.
- [x] Closed S1 on tested code commit `24a008a` (VERSION 0.4.0): unit 821/821, gate 152/152, canary 7/7, full lint exit 0, Technical verification PASS.
  All suite and batch exits were 0; independent raw TAP verification found no failures, skips, missing/duplicate IDs, or bailouts; all eight payload fixtures remained byte-identical.
  Retained reports: `results/unit.0rL0UNVS/report.tap`, `results/gate.FhYO4QhP/report.tap`, `results/canary.Xr44M3z7/report.tap`.

### Restore canonical SDLC state (R1) - CURRENT SESSION-END MISSION

Rachid stopped the observer to discuss SDLC and requested a restoration-first handoff; do not restart the old loop or begin Schema and lean records (S2) before this recovery is complete.
The detached batch finished independently; historical PID 17044 is gone, and absent scratch completion markers are not failed tests.

- [x] Verified S1's completed command exits and complete native TAP; recorded the facts above rather than trusting stale scratch progress.
- [x] Inventoried session-authored non-canonical files and their roles; discovery map: `/home/rbc/.pi/handoffs/2026-10-17-cloudify-canonical-restoration.md`, with a durable root/source index in LOGS.md under "Canonical restoration handoff".
- [x] Compared every authored scratch test/runner with tracked code: the one-case transport prototype was fully subsumed by `tests/unit/remote-bats.bats` case 1 (six cases); nothing unique to port.
- [x] Consolidated supervision into tracked `tests/run-acceptance.sh` + `task acceptance` (commit `e47996a`): selectable suites, repo-relative receipts in `results/acceptance/<run-id>/`, lifecycle semantics in the script header (batch.current is last-started, never liveness); shimmed-`task` smoke passed for success and early-stop paths.
- [x] Migrated both scratch roots byte-identical (cmp-verified, 32 files) into `results/evidence/s{0,1}/` with the original-to-new map in `results/evidence/MAPPING.md`; scratch progress files are superseded records, no longer authoritative.
- [x] SDLC consent obtained; harness updated: radius-scoped gates and canonical test/progress placement landed in `c4424f2`, classification citation now cites Secret markers with suffixes (ADR-042).
- [x] Validated with the cheapest checks only (bash -n, shellcheck, shimmed smoke; no accepted suite rerun); originals removed through recoverable trash only after byte verification.
- [ ] Leave this one plan and the tracked tree clean, commit/push the recovery, then continue the remaining implementation from Schema and lean records (S2), with live-state approval (G4) still pending.

### Schema and lean records (S2)

- [x] Cross Schema approval (G2), then update schemas, bounded validator, valid/invalid fixtures, record goldens, and documentation together.
  Landed in `1c959de`: schemas evolved in place (lean package-state record, event values as recorded forms), 5+13 and 9+14 fixture matrices green, schema README rewritten.
  The record-contract pins are the schema fixtures; the only byte-exact goldens are the payload ones (tests/fixtures/golden/payload), which stayed byte-identical through the cutover (gate 152/152).
- [x] Cut over every producer and consumer, including worker, state apply, adoption, matching, deployment rendering, and replay/seeding readers; do not land a schema-only incompatible writer state.
  Landed in `04bf366` through `e3845df` plus `9610af8`: writers emit the lean shape, readers (seed, show/unset, matching, adoption, describe) consume it; unit 821/821, gate 152/152, canary 7/7 (runs of 2026-10-17; exact TAP paths in LOGS).
  A first-operation verify failure records `failed: true` with no settings and null version; an off-graph dependency's succeeded line reports its own version while the run degrades; the record slot travels via `CLOUDIFY_RECORD_SLOT`.
- [x] Preserve revision monotonicity, host locks, atomic validated replacement, event identity fields, failure preservation, and the target association.
  The transition still validates before atomic replacement and bumps the revision under the host lock; the lean record keeps target/version/revision/user_forced/failed and drops the per-object event ids (events carry previous/resulting revisions instead); `inventory_check` is schema-validity only.
- [ ] Implement an explicit, idempotent old-record conversion with a restricted backup, value-free reports, unresolved-fact refusals, and Git-revert-plus-backup rollback, built for the per-application live sequence (per-application live conversion, ADR-043).
  Converter landed as `cloudify deployment migrate-registry <id> --application <app> [--write]` (lib/migrate-registry.sh): investigate (default, read-only) resolves each record's target and runs the ad-hoc unnamed verify with the record's non-secret values as caller env - playfield facts before any write, per Rachid's ruling that every record must follow an investigation of what is actually deployed; `--write` re-investigates fresh, refuses failed probes by name, backs up, and converts through the one inventory transition, one application at a time.
  Derive targets only from proven facts; never invent adopted bindings or success.
  Test on copied synthetic records first; live conversion waits for Live-state approval (G4).
- [x] Prove native multiline/empty settings, secret-name-only records/events, first-operation failure, failed reconfigure preserving settings, successful verify retaining failure, and successful install/reconfigure clearing failure.
  Pinned by the rewritten suites: worker.bats (verify-failure first op, settings preservation, failed clear on reconfigure-success paths), applied-seeding.bats (**** demand lines, forced filter), schema fixtures (multiline/empty, first-failure, failed-preserves-settings), matching.bats (marker-only secret compare).
- [ ] Close the tool gates and record-golden review.

### Environment-only secret plumbing (S3)

- [ ] Remove secret digest demand/checks from applied seeding and secret backend resolution from runtime secret paths.
- [ ] Remove secret-demand preflight while preserving ordinary required-variable validation; hook failures retain the mapped input name.
- [ ] Snapshot classified names as `****`; replay never exports historical secret literals, placeholders, or inventory secrets over current environment values.
- [ ] Demote `@base64:` to file-store transport and prove decoded multiline ordinary values persist correctly.
- [ ] Prove rotated environment supply, absent optional secrets, missing-secret hook errors, both mapping directions, no backend invocation, and no secret persistence or automatic output capture.
- [ ] Close the tool and fragile gates.

### Defaults ladder (S4)

- [ ] Add application defaults below application-flavor defaults; retire the deployment rung, values-file runtime readers/writers, `vars --deployment` surface, and stored `TARGET_*` bindings.
- [ ] Bind targets from explicit `--target` and inventory-backed manifest state only.
- [ ] Prove every rung, collisions, present-empty claims, deleted defaults, ordinary required inputs, and recipe fallback without exporting mirror text.
- [ ] Verify octop's recorded mirror with a value-free report; back up and delete its live `values.yaml` only after Live-state approval (G4), never touching the application.
- [ ] Close the tool and fragile gates; regenerate only approved and explained payload export differences.

### User-forced seeding (S5)

- [ ] Replace source-label seeding with `user_forced`; environment-applied names gain the bit and ordinary file-sourced names do not.
- [ ] Reconfigure seeds only forced applied values; verify/teardown keep their applied ordinary settings and obtain secrets from this invocation.
- [ ] Change `deployment unset` to array removal under the existing host lock and event commit.
- [ ] Prove forced values survive default changes, unset releases them, deleted non-forced defaults take effect, empty forced values persist, and failed operations do not replace confirmed values.
- [ ] Close the tool and fragile gates.

### Current-state and historical replay (S6)

- [ ] Make replay without `--at` read inventory rather than the newest snapshot; preserve explicit YAML snapshot replay for `--at`.
- [ ] Prove inventory/current defaults/historical ordinary values differ intentionally, missing run history does not block current replay, and secrets always use the new environment after mappings.
- [ ] Close the tool gates.

### Unnamed deployment matching (S7)

- [ ] Replace literal `default` selection with Unnamed deployment matching (ADR-031).
- [ ] Prove generated first name, identical convergence, differing bindings/scalars/secret-name sets, interrupted/unprovable candidates, and ambiguity refusal naming candidates.
- [ ] Prove explicit names still converge in place; implement/wire the currently reserved installation guard so it compares only own-package declared non-secret settings.
- [ ] Close the tool gates.

### Inventory-backed manifest cache (S8)

- [ ] Rebuild from inventory on missing/corrupt/revision-stale reads, retain explicit rebuild, and remove event-reference refusal from inventory apply.
- [ ] Prove multi-host/target binding recovery, `_direct` target recovery, failure-only and settings-only status derivation, and adopted-to-installed reconstruction.
- [ ] Run the fresh-controller acceptance scenario with no local manifests/events/runs/default deployment files or secret-manager dependency; rebuild and continue verify/reconfigure/replay from copied inventory and current environment.
- [ ] Close the tool gates; leave Host origin and continuity (ADR-028) helpers untouched.

### Failure vocabulary and release (S9)

- [ ] Retire runtime `degraded` from worker, runbook completion, derivation, schemas, rendering, fixtures, and pins; retain historical ADR/event evidence unchanged.
- [ ] Prove any failed operation marks failure, passing verify cannot clear it, and successful install/reconfigure can.
- [ ] Re-run full unit, fragile gate, lint, guacamole canary, and the scoped disposable multi-host/recovery E2E on final pushed HEAD.
  Agree any full registry sweep scope before executing it; production deployments are never test fixtures.
- [ ] Verify the planned `0.4.0` pre-1.0 contract release version, bumped at Marker sweep and suffix fallback (S1), including CLI/version override behavior.
- [ ] Close README, runbook/package documentation, schema README, REDESIGN, roadmap, HISTORY, and LOGS; do not edit CHANGELOG or harness files without consent.
- [ ] Remove temporary conversion readers/fixtures only after the approved migration reports zero old artifacts; no permanent runtime dual reader.
- [ ] Finish bounded spec/technical reviews under the project review budgets, address findings, and record final evidence before PR/merge.

## Deferred and protected

No NATS permission broker, ivps path/XDG redesign, Host origin and continuity (ADR-028), guest-generated secret channel, secretspec generation/serve/aware UX, historical secret cleanup, or unrelated wording sweep.
Do not mutate live affine, youtube-mcp, octop, t3code, or the Guacamole oracle pair; oracle adoption is separate work.
Existing unsafe historical snapshots remain private and unchanged.

## Progress and approvals

- Planning only: fetched `origin`; `master` matched `origin/master` at `1f46d5f`, clean before planning.
- The planning SPEC review passed with no must-fix findings before runtime tests began.
- Rachid approved Plan (G1), Schema (G2), and Fragile contracts (G3), then explicitly required a feature branch before implementation; `feat/state-convergence` was created with no implementation edits on master.
- Live-state approval (G4): pending; no production mutation authorized.
- Baseline and prerequisites (S0): COMPLETE; focused checks 7/7, producer/consumer audit complete, Technical verification PASS, unit 804/0, before/after gate 144/0 each, canary 7/0, full lint exit 0.
  S0 closed before implementation; Rachid then authorized Marker sweep and suffix fallback (S1) under the revised classification decision (ADR-042).
- Marker sweep and suffix fallback (S1): COMPLETE at code commit `24a008a`; focused checks, Technical verification, lint, unit 821/821, gate 152/152, and canary 7/7 passed.
- Restore canonical SDLC state (R1) is the active mission; Schema and lean records (S2) and all later slices remain unstarted.
  Technical review found one new-local/input-name collision; isolated classification in a pure helper and passed a regression covering all six new temporary names plus child exports before verification.
  AGENTS.md's classification architecture sentence remains unchanged pending the requested consent; no harness edits were made.
- Full lint found SC2046 on the existing numeric `date +%s` expansion in the remote template; added one localized explanatory shellcheck comment, with no executable change.
  Before-edit fragile gate passed 144/144 with actual task exit 0; before/after `declare -f` payload text is byte-identical by cmp; full task lint now exits 0.
  No golden regeneration occurred; payload body, explicit allow-list, exports, stdin transport, and shadow bytes remain unchanged.
  The detached local owner completed full unit, the after-edit gate, and canary serially with every task and batch exit 0; native reports and actual exits are retained under results and `~/tmp/cloudify-s0`.
- The earlier interrupted attempt planned 797 unit tests and passed through test 426 before its reader received harness cancellation; that attempt produced no complete verdict and is not counted as a pass.
  Preserved partial TAP at `~/tmp/cloudify-s0/interrupted-unit.tap`; do not count it as a baseline pass.
- Rachid confirmed cloudify is dedicated to tests and authorized preparation; Tailscale SSH from the laptop works, while same-host self-connections are refused.
  The unrun conventional-SSH preparation scripts were discarded; no SSH daemon, keys, second host, or copied inventory were introduced.
- Removed only the old Compose project guacamole: two containers and its network; no project volumes remained.
  Bats 1.13.0, libraries, Docker, jq, envsubst, git, curl, and trash-put are present; clean-state checks pass.
- Target-side ivps is not required by the local stack canary; do not claim that canary proves inventory recording.
  The earlier extra-host/inventory recommendation was withdrawn; all tests stay on cloudai:cloudify.
- The recovered transport regression now lives in the unit suite and passed red/green checks on the target; no runtime, recipe, schema, or production changes yet.
