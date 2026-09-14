# State model v2 recovery and completion plan

Goal: repair the committed Phase 2 and Phase 3 foundations, then implement `REDESIGN.md` through completion without carrying rejected code or compatibility layers.

Decision: ADR-022 and ADR-023.

## Why this plan exists

Cloudify was executing `plans/state-model-v2.md`. Rachid detected that the work had drifted away from that plan's own contract, not merely fallen behind it, and directed a recovery instead of more patching. Two independent read-only audits then confirmed the drift with `file:line` evidence: a registry writer that reopened value stores after the dispatch context was built (the second-walk defect the redesign exists to remove), a package-state file that was flat text in a file named `state.json` while its schema required JSON, a remote result channel a recipe could forge, package-instance identity dropped from state keys, and migration fabricating `application_commit`. The uncommitted Phase 4 work was discarded, Phases 1 to 3 were kept as a repairable baseline, and this plan replaced `plans/state-model-v2.md`, now archived as `plans/archived/state-model-v2-attempt1.md`.

The original plan was not wrong about the destination; it was wrong about the state model it would have shipped. This plan keeps the destination and corrects the contract, so the chain is: `plans/state-model-v2.md` (drifted, archived) to this plan: clean baseline (R0), Phase 2 repair (R1), Phase 3 audit (R2), Phase 4 design (R3), then Phases 4 to 9.

This plan supersedes `plans/archived/state-model-v2-attempt1.md`.

The archived plan is implementation history only.

Its completed boxes do not authorize work and must not be copied here.

## Current truth

- [x] Phase 1 schemas, identity rules, fixtures and defect proofs are retained.
- [x] Cloudify was executing `plans/state-model-v2.md`; Rachid detected drift against that plan and directed recovery rather than further patching, and two independent audits confirmed it.
- [x] Phase 2 and Phase 3 commits are retained as a repairable baseline, not accepted as specification-complete.
- [x] Uncommitted Phase 4A code was archived under `~/tmp/cloudify-phase4a-rejected-20260913/` and removed from the repository.
- [x] The rejected `plans/state-model-v2-phase4-design.md` was removed.
- [x] The contradictory `plans/state-model-v2-phase2-design.md` was archived as `plans/archived/state-model-v2-phase2-attempt-design.md` and its live citations repointed.
- [x] No Phase 4 implementation or design is accepted.
- [x] Rachid directed that Cloudify ship one v2 path, with no compatibility switches, dual readers or legacy discovery.
- [x] The only temporary exceptions are one-shot migration commands for old desired inputs, registry records and snapshots; each is deleted after the inventory reports zero old artifacts.
- [x] `lib/shadows/` and `lib/shadow.sh` remain untouched unless a new description, non-breakage argument and explicit consent allow a specific change.

## Where things live

Two files are normative and are the single source of truth:

- **The design** - `REDESIGN.md`: what the system must be.
- **The plan** - this file, through `PLAN.md`: what to do, in what order, behind which gate.

Everything else is a working note. Use them freely, put them wherever is convenient, throw them away. The only requirement is that any spec or plan change ends up in one of those two files.

Four things are neither, and must not be treated as working notes:

- `schemas/v1/` - machine-enforced contracts. `validate.sh` runs them and the fixtures prove them, so they are normative in the executable sense.
- `AGENTS.md` - process rules.
- `LOGS.md` and `HISTORY.md` - required append-only records.
- `GLOSSARY.md`, `README.md`, `ROADMAP.md` - derived explanation. Kept and useful, but they must never contradict the design.

The condition that makes this safe: **a design change lands in `REDESIGN.md` in the same commit as the decision that authorizes it.** Otherwise the design drifts from the decisions and stops being the source of truth.

And where two normative files disagree, that is a defect to fix, not a precedence question to settle.

If something in this plan does not fly, stop and raise it with Rachid; do not fork a new plan, and do not keep executing around the problem.

Superseded plans move to `plans/archived/`. Nothing else is added to `plans/`.

## Authority

The design and the plan are the single source of truth. `REDESIGN.md` says what the system must be; this plan says what to do about it. Where they disagree with anything else, they win.

`AGENTS.md` outranks both for process: it governs how work is done, not what is built.

ADR-022 and ADR-023 remain the accepted decisions behind the design and are the trail for why it changed. A design change updates `REDESIGN.md` and records the decision in an ADR in the same commit.

`schemas/v1/` is the executable form of part of the design. A disagreement between a schema and `REDESIGN.md` is a defect, not a precedence question.

`GLOSSARY.md`, `README.md` and `ROADMAP.md` explain and must not contradict.

Anything else - archived plans, superseded description artifacts, per-slice notes under `tmp/`, the rejected patch under `~/tmp/cloudify-phase4a-rejected-20260913/` - is evidence only, never authority.

No implementation may weaken the design or the plan silently. A required change to either lands in `REDESIGN.md` and this plan with a decision recorded in an ADR, and needs Rachid's consent before code.

## Mandatory execution rules

- Never mark a task complete from a subagent report alone; the lead agent verifies the file, focused tests and diff.
- Never mark an entire phase complete with a bulk checkbox replacement.
- One red test, minimum green implementation, refactor, then the next red test.
- Every slice ends with focused tests and shellcheck before commit.
- Full unit suite runs only at recovery and phase boundaries.
- Run tests in the background into `results/<name>.tap` and poll with plain `tail`.
- Read Cloudify's normal `/tmp/cloudify/logs/<timestamp>.log`; do not create custom diagnostic logs or grep test output.
- Do not use integration or E2E as a debugger: fix what it exposes with L0 to L3 and focused tests first, then re-run it once.
- Run the full disposable E2E at every code phase exit gate, and again at the final gate.
- Push before every test whose remote host pulls from GitHub.
- No compatibility flags, fallback readers, dual writers, legacy path discovery or superseded command aliases.
- A temporary migration reader must be the sole caller of the old format and must have a deletion task in this plan.
- Deleting a migration reader or its fixtures must leave the surviving gates (especially `bash schemas/v1/validate.sh`) passing; name the replacement gate in the same task.
- No code commit while a SPEC or Technical reviewer has actionable feedback on that slice.
- Any slice that changes `lib/`, the `cloudify` router, `lib/shadows/` or `lib/shadow.sh` needs the project CRITICAL GATE first, in this order: a read-only description subagent writes the artifact explaining the bash mechanism at risk, then a plan states explicitly why the change cannot break it, then Rachid gives explicit consent, then the consent is recorded in `LOGS.md`. No tick may be claimed before all four.
- Plan-level reviews are bounded: stop after two consecutive rounds with no must-fix finding, log anything smaller as an implementation checklist item, and let the phase gate settle it on real code. Per-phase reviews of a real diff are the primary gate; reviewing plan prose is not.
- `git status --short` is clean at every committed boundary.

Test levels are fixed. L0 is shellcheck plus syntax. L1 is the real code run on a real machine without dispatching a package. It is not a separate file: `tests/unit/context-wiring.bats` already drives the real transport with a stubbed ssh, asserting the payload text and the ssh argument string, which is exactly this level. Later slices add a driver only if nothing existing covers the new wiring. L2 is one no-verify mutation of the disposable package `fixture-split` (already in `pkg/`) with an inspection of Cloudify's own log. L3 is `PKG_VERIFY_TIMEOUT=30 cloudify verify fixture-split`. L4 is the scoped bats acceptance harness. Every level names a concrete artifact, and no driver is created before the code it drives, so none can be satisfied by an empty green file.

## Phase exit gate (every code phase)

Every code phase (the Phase 2 repair, R1; the Phase 3 audit, R2; and Phases 4 to 9) ends here, and no later phase starts until it passes.
The clean baseline (R0) changes no runtime code and the Phase 4 design gate (R3) writes no code, so those two run the reviews but skip the E2E lines.

- [x] Full unit suite green on the phase's final HEAD (644 ok, 0 not ok, `results/target-timeout/report.tap`).
- [x] Full disposable end-to-end run green in `tests/e2e/two-host-application.bats`, created in the Phase 2 repair (R1) and run as an operator would: two disposable hosts, the scenario set unlocked by this phase, and `CLOUDIFY_CMD="cloudify --no-defaults"`. (4 scenarios green, 4 later-phase scenarios skipped by name, 0 failures.)
- [x] Run the phase's unlocked E2E scenarios only: the Phase 2 repair (R1) and the Phase 3 audit (R2) run install, verify and interruption; the package state phase (Phase 4) onward adds reconfigure, shared claim and conflict; the provenance phase (Phase 7) adds first teardown and last teardown. A scenario whose phase has not landed stays marked not-yet-unlocked in the suite, never deleted and never silently skipped. (The four later-phase scenarios stay skipped with their unlocking phase named.)
- [x] Every disposable resource torn down and the host policy proven restored, with no leftover node, binding or claim. (Both `e2e-2h-a` and `e2e-2h-b` deleted in teardown_file.)
- [x] Fresh-context SPEC review against `REDESIGN.md`, ADR-022, ADR-023, the schemas and this plan, returning exactly `PASS` with no actionable feedback. (claude, 2026-09-14, PASS with file:line evidence; prior FAILs closed.)
- [x] Fresh-context Technical review on a different model covering correctness, modularity, DRY, KISS, maintainability, Bash safety, error paths and lock ordering, returning exactly `PASS` with no actionable feedback. (codex, 2026-09-14, PASS with file:line evidence.)
- [x] Require every reviewer to show its work: alongside `PASS`, a checklist mapping each `REDESIGN.md` success criterion and each listed Technical concern to concrete file:line evidence. A bare `PASS` without that mapping is not a `PASS` and must be sent back. (Both reviewers returned the mapping.)
- [x] Fix every review finding and re-review from a fresh context; defer none to a later phase. (Both blockers and all notes fixed, then re-reviewed to PASS.)
- [x] Commit and push only when every line above is green. (Committed `29f4890`, pushed to `state-model-v2-phase1`.)

The fleet E2E (`tests/e2e/k3s-multi-cluster.bats`, four throwaway nodes, live ACL mutation, up to fifteen minutes per node) is not a per-phase gate: it validates k3s UX rather than the state model, so it runs once at the Phase 9 final gate, where the tailnet and ACL restore is part of the exit criteria.
If the two-host E2E is genuinely unrunnable for a phase, that is a blocker to raise with Rachid, not a line to tick with a substitute.

## Known implementation risks carried into the Phase 2 repair (R1)

Surfaced by plan review, each verified against the code, none yet fixed because they are code:

- Four places read the context as flat text and go silent, not loud, once it is JSON. A missed one empties the envsubst allow-list and payload forwarding stops exporting package values without an error: the allow-list `sed` (`lib/remote.sh:123`), `cloudify_context_read` (`lib/context.sh:364-376`), the DEBUG rendering loop (`lib/remote.sh:250-260`), and the snapshot resolver's store read (`lib/runbooks.sh:189-191`). Each needs a test that fails if it returns nothing.
- Context removal has two live leaks today: a direct package command with no deployment (`lib/registry.sh:395-397` returns before its `rm` at `:418`), and `cleanup()` being DEBUG-guarded (`lib/utils.sh:77-79`). The fix must keep the single existing EXIT trap and must not leave the file behind under DEBUG.
- `tests/unit/golden-fixtures.bats` pins the payload matrix and the registry record in one file. The registry half must go with the writer while the payload half stays, or the byte-exact golden proof (R1.3) is lost.
- `lib/state.sh` keeps a hand-rolled JSON encoder and field parser beside `jq`, so "one encoder" is not yet true (fixed by the application and runbook audit, R2.2).
- `tests/e2e/two-host-application.bats` now exists and its four Phase 2 repair scenarios pass; the remaining exit-gate work is the two independent reviews.

## Clean baseline (R0)

Outcome: the branch contains committed Phases 1-3 only, the rejected Phase 4 work is recoverable outside the repository, and the tracker tells the truth.

- [x] Archive the rejected tracked diff, untracked files and rejected Phase 4 design under `~/tmp/cloudify-phase4a-rejected-20260913/` with verified SHA256 sums.
- [x] Restore every tracked Phase 4A file to `HEAD` without resetting committed Phases 1-3.
- [x] Trash `lib/state-pkg.sh` and `tests/unit/state-pkg.bats` recoverably.
- [x] Remove the rejected Phase 4 design from the repository.
- [x] Archive the contradictory attempt plan as `plans/archived/state-model-v2-attempt1.md`.
- [x] Point `PLAN.md` to this recovery plan.
- [x] Add ADR-023 and align `REDESIGN.md` and `GLOSSARY.md` with the one-path decision.
- [x] Rename schema classification `legacy-heuristic` to `heuristic` and update its valid fixtures and docs.
- [x] Record the recovery decision and the exact retained baseline in `LOGS.md` and `HISTORY.md`.
- [x] Harden `task sync`: mirror `lib`, `tests`, `pkg`, `schemas` and `runbooks` with `--delete`, because the container is an rsync target, not a git checkout, so a deleted file or a stale schema otherwise survives and silently pollutes a run.
- [x] Run `task lint` (rc 0) and the full unit suite on the restored baseline (619 ok, 0 not ok, `results/r0-unit-clean.tap`).
- [x] Commit and push the clean recovery baseline (667d96f).

## One real resolution: the Phase 2 repair (R1)

Outcome: one private dispatch context contains everything every later consumer needs, and no consumer reopens a value source.

### CRITICAL GATE before any `lib/` edit (R1.0)

The description artifact exists: `tmp/state-model-v2-forwarding-description.md` (627 lines, written 2026-09-13 by a read-only subagent; its durable trace is in `LOGS.md`). It cites the forwarding path, the context, the registry and snapshot writers, the shadows, and `_cloudify_registry_context_raw` as the defect.

- [x] Spawn a read-only subagent whose only mission is to describe how the env-var forwarding path works end to end: `declare -f` payload extraction, the `envsubst` allow-list, single-quoted `$VAR` remoting, first-write-wins claiming, and where the registry record and snapshot are written.
- [x] Write that description as an artifact and cite it from the plan before touching code.
- [x] Use the artifact's section "What a safe Phase 2 fix may and may not touch" as the starting invariant list, dropping the two invariants the artifact marks as superseded by design (the metadata-only context and the frozen allow-list) and following `REDESIGN.md` where they differ. Done in `tmp/state-model-v2-phase2-non-breakage.md`.
- [x] State explicitly in the plan why the context change cannot break forwarding or the shadows: name each invariant preserved, each mechanism traced, and the test that re-asserts it. Written before the first `lib/` edit in `tmp/state-model-v2-phase2-non-breakage.md`, with its durable trace in `LOGS.md`.
- [x] Obtain explicit consent from Rachid and record it in `LOGS.md`. Consent given 2026-09-13 for the Phase 2 repair, scope: the seven files listed in R1.2, no shadow or recipe changes.

### Freeze the context contract before code (R1.1)

The context keeps its current flat `key: value` format. Converting it to JSON with a schema and a `jq` dependency is deferred and roadmapped; see "Dispatch context as a JSON contract" in `ROADMAP.md`. The reason: the conversion is what makes the four flat readers fail silently rather than loudly, and the repair does not need it.

- [x] Create `tests/e2e/two-host-application.bats` with every scenario named and the phase that unlocks each one. Done for the Phase 2 repair: 4 scenarios green, 4 later-phase scenarios skipped by name.
- [x] The L1 driver is not a new file. `tests/unit/context-wiring.bats` already runs the real code against a real machine without dispatching a package, so a `tests/unit/drivers/context.bats` would duplicate it and add a file rather than coverage. Later slices add a driver only if nothing existing covers the new wiring.
- [x] Add one field per name: the raw source form, the exact text the registry record and the snapshot must contain. It is carried in the context's transport encoding `t:<text>` or `b:<base64>` (chosen by `_cloudify_vars_raw_encode`, so a raw text that itself looks encoded is never mistaken for the transport); the record and snapshot decode it and keep their own existing `@base64:` convention for multiline values. Nothing else about the format changes. Pinned by `tests/unit/context-raw-form.bats`.
The full per-name field set is deferred with the JSON context contract.
- [x] Include deployment identity, resolved host identity and address, phase and action (verified by `tests/unit/context.bats`, "`cloudify_context_read` round-trips each field"). The identity fields whose producers land later, and the null rule for them, moved to the deferred JSON context work.
- [x] Secret classification origin is exactly `explicit`, `heuristic` or `none`; the stale `legacy-heuristic` term is removed from schemas, fixtures and docs.
- [x] Permit resolved plaintext transiently in both this 0600 ephemeral context and collector shell exports, as `REDESIGN.md` requires; neither channel may be removed before payload execution.
- [x] Keep secret plaintext out of logs, debug output, state, runs and events. The raw source form of a secret is permitted in the context for the same reason the resolved form is, and the context's removal is what bounds it. Asserted for logs, the context file and the registry record (`tests/unit/context.bats`, `tests/unit/context-wiring.bats`, `tests/unit/golden-fixtures.bats`); state, runs and events have no writer yet, so the scan extends with them.
- [x] Validate the context with an explicit check before payload construction and before any mutation: the required fields are present and the raw encoding is well formed (`cloudify_context_validate`), and a malformed context fails loudly, because a silently empty context stops payload forwarding with no error. The stricter rule - every expected field present and no unexpected field - is deferred with the JSON schema that will own "expected fields".
- [x] Obtain a fresh SPEC review and Technical review of this contract, each returning `PASS` with no actionable feedback. Both returned `PASS` at the Phase 2 exit gate.

### Replace the incomplete context (R1.2)

This slice changes a foundational mechanism (value forwarding), so its implementation is gated behind a fresh subagent review of the design against the forwarding invariants and the shadow contract. That review has run; see the rejected option below.

- [x] Obtain a fresh subagent review of this design against the forwarding invariants and the shadow contract before any code. Outcome: the internal-temp-file conversion below was **rejected**, and the repair is limited to the defect itself.

**Rejected option: converting the context builder's two internal temp files to associative arrays.** Kept here so it is not re-proposed. The three files each do a distinct job, and two of them have properties a naive conversion breaks:

- The claim ledger is two things at once: the list of provided names, and the signal that arming is on. `_CLOUDIFY_VARS_LEDGER` is tested for emptiness in six places (`lib/vars.sh:58,175,290,308,366,427`), and reading an associative array as a scalar expands element `[0]`, which is always empty. Keeping those tests would make the claim check return success unconditionally, so every later source would overwrite and first-wins would silently become last-wins, and the caller-environment branch would stop firing.
- **The ledger's iteration order is load-bearing for the payload bytes.** The context writes `value.<NAME>.*` in `sort -u "$ledger"` order (`lib/context.sh:310-314`), the allow-list is recovered from that order (`lib/remote.sh:123`), and it becomes the payload's export order, pinned byte-for-byte by the eight `tests/fixtures/golden/payload/*` cases. `${!array[@]}` yields hash order.
- A `declare -gA` array would leak claims across dispatches in one shell, and the test suite builds the context repeatedly. `local -A` plus an exact name match is required, and a name mismatch would be silently empty.
- The verify path arms the same variable with an empty `mktemp` used purely as a non-empty sentinel (`lib/package-api.sh:346-349`, behaviour pinned by `tests/unit/verify-vars.bats:66-79`), so that file would have to join the slice.
- An existing structural guard greps for the provenance symbols (`tests/unit/context.bats:572-574`) and would need rewriting in the same slice.

The gain was one `grep -qx` per claimed name and one parse-back. Not worth that risk surface in the same slice that already touches the most breakage-prone code in the repository.

- [x] Prove the repair leaves shadowing untouched: no shadowed command (`sudo`, `apt-get`, `add-apt-repository`, `git`) and no file under `lib/shadows/` is read, called or modified by it. `git diff 667d96f..HEAD -- lib/shadows lib/shadow.sh pkg/` is empty, and the payload bytes stay pinned by the eight `tests/fixtures/golden/payload/*` cases.

- [x] Build the dispatch's value set once from the source ladder at context creation.
- [x] Do not change the context builder's internal temp files: the claim ledger and the provenance file stay files. See the rejected option above for why.
- [x] Add the raw source form to what the builder records per name, beside the existing provenance record, so the registry record and the snapshot can be built from the context without reopening a store.
- [x] Preserve install precedence exactly as `REDESIGN.md` states, strongest first: caller or step environment, deployment desired inputs, application defaults, package defaults, global defaults, recipe defaults. Pinned by the walker tests in `tests/unit/vars.bats`.
- [x] Resolve application input mappings only into names a package in the dispatch declares, never into an arbitrary ambient name (`tests/unit/context.bats`, "application inputs: a mapping is names only, so an unmapped package variable is untouched").
- [x] Preserve file-store secret reference resolution and caller-environment literal timing (`tests/unit/context.bats`, "store references arrive decoded while the same text in the caller env arrives verbatim").
- [x] Compute literal-secret digests while the resolved plaintext is in the private context.
- [x] Fix context-removal ownership before the context carries plaintext, in two layers that both work within the existing exit path. First, remove each dispatch's context in the wait loop's success path too, mirroring the failure path (`cloudify:821-824`), so a direct package command with no deployment stops leaking (today `_cloudify_registry_record_bg` returns early at `lib/registry.sh:395-397` and its `rm` at `:418` is never reached). Second, declare `_CLOUDIFY_BG_CONTEXT` at global scope rather than `local -A` (`cloudify:412`), because an EXIT trap armed inside `main()` runs after `main()` returns, when a local is already unset and the array looks empty; then add the removal loop at the top of the existing `cleanup()` (`lib/utils.sh:74-87`), before its `DEBUG` early-return, so the single `trap cleanup SIGINT SIGTERM ERR EXIT` (`cloudify:98`) covers signals and early exits without a second trap. Do not arm a second EXIT trap: it would replace `cleanup` for the EXIT signal and silently disable `CLOUDIFY_TMP` cleanup, and do not use a RETURN trap at context creation, which fires before the backgrounded child fills the file. Implemented, and today the backstop is the swept context directory (`lib/utils.sh`).
- [x] Update the snapshot resolver in `lib/runbooks.sh` (the seed block around `lib/runbooks.sh:1390`) so it stops calling `_cloudify_vars_store_get` and reads the same context (`tests/unit/context-raw-form.bats`, "no second walk: the snapshot resolver survives the sources disappearing").
- [x] Replace `_cloudify_registry_context_raw`, the committed store re-opener, with a reader of the context's `value.<name>.raw` field: it never reopens a value store, so the second-walk defect is gone. (`cloudify_context_raw_value` existed only in the rejected patch and is already gone.)
- [x] Make preflight, the `envsubst` allow-list names, registry observation, snapshot writer and future state/event writers consume this context only.
- [x] Never read a resolved value back from the context to build the payload; values still flow resolver shell exports to one envsubst pass to single-quoted remote exports.
- [x] Keep collector exports in the calling shell and never capture them with command substitution.
- [x] Keep the payload on stdin and keep context paths and values off argv (`tests/unit/context-wiring.bats`, "the ssh argv is only the host and 'bash -s'").
- [x] Write the context once, after the walk completes. A walk that writes values into the context as it goes silently becomes last-writer-wins and reintroduces the defect. The write is a single `{ ... } > "$out"` block after the walk loop (`lib/context.sh`), and the no-second-walk proofs (`tests/unit/context-raw-form.bats`) re-assert the outcome by destroying every source after resolution and requiring the record and snapshot to still answer from the context.

### Prove the root defect is gone (R1.3)

- [x] Create a context, then mutate or trash every source file; payload, registry and snapshot must still use the original context answer (`tests/unit/context-raw-form.bats`, the two "no second walk" proofs).
- [x] Prove the rule: when a top-level package and a dependency declare the same name, the named package's value wins and the dependency's does not (`tests/unit/context.bats`, "rightmost package wins and dependency recursion resolves through the context").
- [x] Cover environment, desired input, application default, package default, global default and recipe default independently (walker tests in `tests/unit/vars.bats`; `tests/unit/context.bats`, "context build exports the expected value for every source combination").
- [x] Cover required, optional and declared-default names (`tests/unit/vars.bats`, "declaration: bare NAME is required, NAME=value defaulted, NAME= optional").
- [x] Cover plain, escaped-at, backend reference, multiline, spaces, quotes, colons and shell metacharacters (`tests/unit/context-raw-form.bats` for tab, multiline and look-encoded raw text; `tests/unit/context.bats` for reference-versus-verbatim; `tests/fixtures/golden/payload/*` for multiline and base64; `tests/unit/remote-stdin.bats` for single quotes and metacharacters; `tests/unit/vars.bats` for spaces and special characters).
- [x] Assert no fixture secret appears in debug output or any persisted artifact (debug output and the log: `tests/unit/context-wiring.bats`, `tests/unit/context.bats`; the registry record: `tests/unit/golden-fixtures.bats`). State, runs and events have no writer yet, so their scan lands with them.
- [x] Prove no context file survives a successful, a failed and an interrupted dispatch, including a direct package command with no deployment and with `CLOUDIFY_LOG_LEVEL=DEBUG` (`tests/e2e/two-host-application.bats` scenario 3; `tests/unit/context-raw-form.bats`, "cleanup: the swept context directory removes a runbook context too"; `tests/unit/context-wiring.bats`, a real no-deployment dispatch).
- [x] Prove the corrected resolution keeps payload and registry bytes identical to the pre-deletion goldens; treat any changed byte as a defect to explain, not a new golden to accept (`tests/unit/golden-fixtures.bats`: eight payload cases, nine registry cases).
- [x] Run focused context, vars, remote, registry, runbook, replay and router suites. Green.
- [x] Run `task lint` and the full unit suite: lint rc 0, 644 ok, 0 not ok.
- [x] Pass the Phase exit gate (two-host E2E, SPEC review, Technical review) before committing. The two-host end-to-end run is green (4 scenarios, 4 skipped by name); both reviews returned `PASS` with evidence.

## Audit and trim the Phase 3 foundations (R2)

Outcome: application identity, desired inputs, phase selection and manifests match the specification with one implementation each.

### CRITICAL GATE before any `lib/` edit (R2.0)

- [ ] Reuse the forwarding description artifact (R1.0), or extend it, to cover whatever Phase 3 code the audit will change.
- [ ] State why each Phase 3 fix cannot break the forwarding path, the shadows or any recipe, and obtain Rachid's consent recorded in `LOGS.md`.

### Manifest and state-root audit (R2.1)

- [ ] Prove every `manifest.json` is actual JSON that validates against `schemas/v1/deployment-manifest.schema.json` before atomic replacement.
- [ ] Prove component validation happens before any path creation.
- [ ] Prove manifest writes take one deployment lock and no host lock is held at the same time.
- [ ] Prove lifecycle ordering: `applying` before mutation, `active` after install plus verify, `degraded` after observed failure.
- [ ] Prove a killed writer remains discoverable without fabricating a run record.
- [ ] Keep applied package values out of the manifest.
- [ ] Create a manifest only from an application run whose current commit is proved; old desired-input migration never fabricates a manifest or application commit.

### Application and runbook audit (R2.2)

- [ ] Keep only `runbooks/<application>/<flavor>/runbook.md` discovery.
- [ ] Keep only nested desired inputs at `deployments/<application>/<flavor>/<deployment>/values.yaml`.
- [ ] Keep existing `cloudify deployment migrate` as the sole reader of the old single-ID desired-input file and mark it for deletion in the read surface phase (Phase 8); the migration step (4.7) introduces `cloudify state migrate-registry` as the sole old-registry reader.
- [ ] Prove `inputs:` and `map:` use one parser and that a mapping feeds only names a package in the dispatch declares.
- [ ] Prove bare `app run` selects install then verify and can never select teardown through `--yes`.
- [ ] Prove selected-phase preflight checks only the selected phases.
- [ ] Prove target bindings persist and ordinary reruns cannot silently rebind them.
- [ ] Prove direct package commands bypass application manifests as specified.
- [ ] Delete dead aliases, duplicate parsers, duplicate path builders and stale compatibility language.
- [ ] Reduce `lib/runbooks.sh`, `lib/state.sh`, `lib/context.sh`, `lib/deployments.sh` and `lib/vars.sh` where the same fact is parsed or formatted more than once; inline each duplicate into one existing parser rather than adding another abstraction layer.
- [ ] Replace `lib/state.sh`'s hand-rolled JSON encoder, field reader and bindings parser (`_cloudify_manifest_render`, `_cloudify_manifest_field_file`, `_cloudify_manifest_parse_bindings`) and its optional-jq shell fallback with `jq`, so the JSON artifacts (the deployment manifest, run records, package state) share one encoder and one validator.
- [ ] Replace the all-zeros `_CLOUDIFY_MANIFEST_NULL_COMMIT` sentinel with real `null` in the manifest and run records, now that the schemas allow it, and make the shell manifest validator accept null only with `development_override: true`.

### Phase 3 gate (R2.3)

- [ ] Run focused runbook, replay, target, deployment, state, vars and router suites.
- [ ] Run a real L1 driver in `cloudai:cloudify` without dispatch.
- [ ] Run `task lint` and the full unit suite.
- [ ] Pass the Phase exit gate (two-host E2E, SPEC review, Technical review) before committing.

## Fresh Phase 4 design before code (R3)

Outcome: a reviewed Phase 4 design replaces the rejected flat-state and unsafe-stream attempt.

- [ ] Write a new `plans/state-model-v2-phase4-design.md` from `REDESIGN.md`, the corrected context schema and the package-state/event schemas; do not copy the rejected patch.
- [ ] State is actual JSON and validates against `schemas/v1/package-state.schema.json` before atomic replacement.
- [ ] No package state writer lands before the immutable event writer exists.
- [ ] The design must specify tightening the package-state schema so every new applied, attempt, health and claim object carries a non-null event ID; migration also emits its own event. The schema and fixture edit itself lands in the state and event substrate step (4.1), not in this design-only gate.
- [ ] Allow `applied.application_commit: null` only for a proved old-registry migration; require a 40-hex commit for every new application mutation and record the migration origin in its event.
- [x] Keep `application_commit` nullable in the manifest and run schemas with one `allOf` rule requiring `development_override: true` whenever it is null, so a dirty or unidentified tree never forces a fabricated commit.
- [x] Add the matching valid fixtures (`unproved-commit-development-override` for manifest and run, the migrated-observation package state) and invalid fixtures (`null-commit-without-development-override` for manifest and run), and keep `bash schemas/v1/validate.sh` green.
- [ ] Every state transition is event first, then state with the event ID and revision plus one.
- [ ] Move the event-directory, event-ID, event-first commit and lock-integration work formerly listed in Phase 6 into Phase 4 before the first state writer.
- [ ] Prove application commit before the first event or state writer: application runs use their clean HEAD; direct package commands and migration keep it null rather than fabricating provenance.
- [ ] Keep last successful `applied`, `last_attempt`, `health` and active claims separate.
- [ ] Key every result and state commit by its reported package instance, never by a dispatch-wide substitute.
- [ ] Use one lock keyed by durable host identity only across remote mutation and all reported result commits; package and instance identify state subjects, not locks, and no nested package lock exists.
- [ ] Release the host mutation lock before acquiring the deployment manifest lock.
- [ ] Treat recipes as trusted but noisy: framing prevents accidental collisions, not a hostile remote root.
- [ ] Generate a random per-dispatch nonce in the local parent, bake it into the outer remote shell without exporting it to the child cloudify process or recipe, and emit the frame only after that child exits.
- [ ] Frame exact start, encoded length, digest and end markers; reject missing, duplicate, truncated or malformed frames.
- [ ] Pass every non-frame stdout byte through unchanged.
- [ ] Keep local results in a private file and remote results in the framed stdout tail after the child command exits.
- [ ] Include outcome, parent, package instance and phase for every attempted top-level package and dependency, with no values.
- [ ] Reconcile results against every precomputed top-level package and dependency and fail closed on an unexpected package.
- [ ] Freeze lock, state, event and result-frame tests before implementation.
- [ ] Obtain independent SPEC and Technical design reviews, both `PASS` with no actionable feedback; this gate writes no code, so it runs the reviews only and skips the E2E lines.
- [ ] Obtain explicit Rachid consent for the reviewed Phase 4 design before code.

## Physical package state, events and claims (Phase 4)

Outcome: one physical installation is represented once, every mutation has an immutable event, and one deployment cannot break another.

### CRITICAL GATE before any `lib/` edit (4.0)

This phase touches the remote result transport and the host lock in `lib/remote.sh`, plus the writers in `lib/state.sh`, so the gate applies in full.

- [ ] Extend the forwarding description artifact (R1.0) to cover the framed-result transport and the lock, citing the forwarding invariants it must not break.
- [ ] State explicitly why the framed result and the host lock cannot break payload forwarding, the shadows or any recipe.
- [ ] Obtain Rachid's explicit consent and record it in `LOGS.md`.

### State and event substrate (4.1)

- [ ] Complete the deferred JSON dispatch-context contract from `ROADMAP.md` as this phase's first step, before its state and event writers run, under its own consent and review. Nothing else in this phase depends on it: the writers take identity from the parent (`ADR-024`) and read only the context's values, which the flat format already carries: the schema; the full per-name fields (declaration kind, resolved runtime form, secret classification origin); the identity fields whose producers land later (application commit, run and step IDs, package instance) with the rule that a field without a producer stays null; the projections from each context value into `package-state.applied.values`, `package-state.last_attempt.requested` and event `values`; the `jq` readers that replace the flat-line parsers (the allow-list extraction in `lib/remote.sh`, `cloudify_context_read`, and the DEBUG loop); and validation strictness (every expected field present, no unexpected field).
- [ ] Tighten `schemas/v1/package-state.schema.json` so every new applied, attempt, health and claim object carries a non-null event ID, add the matching fixtures, and keep `bash schemas/v1/validate.sh` green.

- [ ] Add collision-resistant run and event IDs without a new runtime dependency.
- [ ] Write immutable Cloudify-owned event files under the Cloudify state root.
- [ ] Validate every event against `schemas/v1/event.schema.json` before create.
- [ ] Create one JSON package-state file per host, package and package instance.
- [ ] Validate next state before atomic replacement.
- [ ] Create the event first, then replace state with revision plus one and that event ID.
- [ ] Detect and report an event whose resulting revision is absent from state and state pointing to a missing event.
- [ ] Never infer remote rollback from a local write failure.

### Package instance and host identity (4.2)

- [ ] Default package instance to `default`.
- [ ] Reject a non-default instance unless the recipe explicitly declares support.
- [ ] Include package instance in context views, result frames, state subjects, claims and events; the host lock remains keyed only by durable host identity.
- [ ] Use ivps node or instance identity for inventory hosts.
- [ ] Reject durable external-host state until its SSH host key is accepted in Phase 5.

### Host lock and result channel (4.3)

- [ ] Acquire one bounded host mutation lock before remote execution.
- [ ] Hold it through every top-level and dependency result commit.
- [ ] Use no nested package lock.
- [ ] Print holder metadata on timeout.
- [ ] Implement and validate the reviewed framed result protocol.
- [ ] Prove recipe stdout and stdin are unchanged.
- [ ] Fail and mark degraded when a successful dispatch has no valid result frame.
- [ ] Fail the commit when a reported package or instance was not precomputed.
- [ ] Commit successful dependency results, not only CLI package words.
- [ ] Release the host lock before updating the manifest.
- [ ] Once package state is written here, stop the runtime registry observation writer: the v2 package state becomes the single record of what landed, and the old registry record-write path is deleted rather than kept beside it.
- [ ] Split `tests/unit/golden-fixtures.bats` in the same slice: delete only the registry-record half and its `tests/fixtures/golden/registry/*` cases, and keep the `tests/fixtures/golden/payload/*` matrix that the byte-exact proof (R1.3) depends on. The record-format fixtures move to the `cloudify state migrate-registry` reader's suite in the migration step (4.7).
- [ ] Keep the context-removal ownership installed in the Phase 2 repair (R1) working when the registry writer goes: the wait-loop removal becomes unconditional and the process EXIT trap stays, both proved by the same success, failure and interruption test.
- [ ] Keep only the migration command's registry reader until Phase 8 deletes it.

### Phase-specific resolution (4.4)

- [ ] Install uses the corrected Phase 2 context and creates a missing physical instance or compatible claim.
- [ ] Reconfigure uses caller or desired inputs above the last successful applied source forms and defaults below them.
- [ ] Verify and teardown seed from last successful applied source forms.
- [ ] A failed last attempt never seeds another phase.
- [ ] A literal secret represented by digest only must be resupplied by caller or desired inputs and match before verify or teardown.
- [ ] Changed defaults never silently alter an existing claim.

### Claims and adoption (4.5)

- [ ] Store claims inside the physical package-state JSON.
- [ ] Key each claim by application, flavor, deployment, stable step ID and package instance.
- [ ] Compare non-secrets by source form, references by reference and literal secrets by digest.
- [ ] Add a claim only after successful compatible installation or adoption.
- [ ] Install over an existing compatible claim is a no-op followed by verify.
- [ ] Explicit differing input fails before mutation and directs the operator to reconfigure or upgrade.
- [ ] An unclaimed compatible package receives a claim without mutation.
- [ ] A differing unclaimed package requires `--adopt` and configure support.
- [ ] Never print either side of a secret conflict.

### Uninstall protection and failure state (4.6)

- [ ] Release every claim owned by the deployment, including dependency claims.
- [ ] Skip physical uninstall while another claim remains.
- [ ] Uninstall only when the last claim is released and the teardown phase names the package.
- [ ] Leave an unclaimed dependency installed unless teardown names it.
- [ ] Put claim checks before recipe code.
- [ ] Preserve `applied` on every failed install, reconfigure, verify or uninstall.
- [ ] Record failed `last_attempt` and degraded or unknown health.
- [ ] Add no claim after an unsuccessful first install.
- [ ] Keep an existing claim after unsuccessful reconfigure.

### Migration and the Phase 4 gate (4.7)

- [ ] Add temporary `cloudify state migrate-registry` as the sole old-registry reader.
- [ ] Map only facts the registry proves; write `application_commit: null` and a migration event when the old record cannot prove provenance.
- [ ] Make migration dry-run first, idempotent and value-safe.
- [ ] Run focused package API, context, state, event, registry, router and runbook suites.
- [ ] Run one real shared-dependency case only after L0 through L3 pass.
- [ ] Run `task lint` and the full unit suite.
- [ ] Pass the Phase exit gate (two-host E2E, SPEC review, Technical review) before committing.

## Explicit secrets, ephemeral outputs and SSH identity (Phase 5)

Outcome: classification is enforceable, no new artifact copies plaintext secrets or automatic outputs, and external-host state has durable identity.

### CRITICAL GATE before any `lib/` edit (5.0)

This phase touches secret classification, the outputs channel and the SSH transport, so the gate applies in full.

- [ ] Extend the forwarding description artifact (R1.0) to cover secret classification, the `CLOUDIFY_OUTPUTS_FILE` channel and the SSH option set, citing the shadow and forwarding invariants at risk.
- [ ] State explicitly why the secret, output and SSH changes cannot break payload forwarding, password injection or recipe auth.
- [ ] Obtain Rachid's explicit consent and record it in `LOGS.md`.

- [ ] Validate explicit package and application secret declarations through one parser.
- [ ] Keep `heuristic` as defense in depth and never call it legacy.
- [ ] Expose classification without content through `cloudify vars declared`.
- [ ] Persist secret references where available and digest plus redaction for literal secrets.
- [ ] Keep runtime plaintext only in the private context and target process.
- [ ] Preserve the 0600 in-run `CLOUDIFY_OUTPUTS_FILE` and `OUT_<name>` channel.
- [ ] Stop writing automatic `output.*` fields anywhere.
- [ ] Add one explicit command to persist a later-run desired input deliberately.
- [ ] Log only names, source labels and classification.
- [ ] Scan logs, manifests, state, runs and events for fixture secrets, and assert no context file remains after cleanup.
- [ ] Add external-host SSH key acceptance, verification and explicit rotation as its own slice, never bundled with secret or output work.
- [ ] Keep payload stdin transport and credentials unchanged while host-key policy changes.
- [ ] Run that slice's own L1 transport driver and L2 remote install before any broader acceptance test.
- [ ] Cover key match, mismatch, first acceptance and approved rotation.
- [ ] Run focused secret, vars, context, remote, state, event and runbook suites.
- [ ] Run `task lint` and the full unit suite.
- [ ] Pass the Phase exit gate (two-host E2E, SPEC review, Technical review) before committing.

## Run lifecycle and repair detection (Phase 6)

Outcome: runs are durable, interruptions and event-state gaps are reportable, and events remain audit rather than replay commands.

### CRITICAL GATE before any `lib/` edit (6.0)

This phase touches the run writer and the dispatch epilogue in `lib/runbooks.sh`, so the gate applies in full.

- [ ] Extend the forwarding description artifact (R1.0) to cover the run snapshot writer, its replay reader and the dispatch epilogue that owns context cleanup.
- [ ] State explicitly why the run and epilogue changes cannot break payload forwarding, the shadows or any recipe.
- [ ] Obtain Rachid's explicit consent and record it in `LOGS.md`.

- [ ] Write a schema-valid run record with `running` before the first selected step.
- [ ] Finish it as `succeeded`, `failed` or `interrupted` with writer and boot identity.
- [ ] Store selected phases and deployment identity, but no resolved values or automatic outputs.
- [ ] Link events by run and stable step IDs.
- [ ] Keep package mutation serialized by the Phase 4 host lock.
- [ ] Keep manifest updates under the deployment lock after the host lock is released.
- [ ] Add `cloudify state check` report-only detection for missing events, missing revisions, duplicate or regressed revisions and stale writers.
- [ ] Add repair only for deterministic local state transitions.
- [ ] Make no claim of multi-operator safety; one local filesystem is the concurrency boundary.
- [ ] Remove snapshot writing after run records plus desired inputs and bindings reproduce every supported replay input.
- [ ] Delete `deployment replay` when the run record path replaces it; do not keep an alias.
- [ ] Run focused run, event, state, runbook and concurrency suites.
- [ ] Run `task lint` and the full unit suite.
- [ ] Pass the Phase exit gate (two-host E2E, SPEC review, Technical review) before committing.

## Pinned provenance, safe teardown and upgrade (Phase 7)

Outcome: teardown releases only owned resources and today's branch tip is never presented as yesterday's application.

### CRITICAL GATE before any `lib/` edit (7.0)

This phase touches commit pinning and the teardown path across `lib/runbooks.sh`, `lib/state.sh` and `lib/remote.sh`, so the gate applies in full.

- [ ] Extend the forwarding description artifact (R1.0) to cover commit resolution, remote execution and the teardown dispatch.
- [ ] State explicitly why pinning and teardown cannot break payload forwarding, the shadows or any recipe.
- [ ] Obtain Rachid's explicit consent and record it in `LOGS.md`.

- [ ] Require a clean commit for production application runs.
- [ ] Keep an explicit development override marked unreproducible.
- [ ] Record the commit in manifests, package state, runs and events only when proved.
- [ ] Load the runbook and package recipes from the manifest's commit for reconfigure and teardown.
- [ ] Fail if that commit is unavailable.
- [ ] Prove the remote host executes the intended commit before historical teardown is enabled.
- [ ] Select package subjects from claims and physical uninstalls from the pinned teardown phase.
- [ ] Release dependency claims with no uninstall action while leaving the dependency installed and unclaimed.
- [ ] Keep transport and policy access alive until software teardown completes.
- [ ] Refuse to remove desired inputs or manifest while any claim remains.
- [ ] Keep runs and events after complete teardown.
- [ ] Block ordinary reconfigure and teardown on commit drift.
- [ ] Add explicit upgrade or migration with stable-step preview and treatment for removed claims.
- [ ] Run focused teardown, claim, provenance, runbook and router suites.
- [ ] Run `task lint` and the full unit suite.
- [ ] Pass the Phase exit gate (two-host E2E, SPEC review, Technical review) before committing.

## Read surface, one-shot migration and deletion of bridges (Phase 8)

Outcome: operators inspect state through commands, all known old data is migrated once, and no migration or old-format code remains.

### CRITICAL GATE before any `lib/` edit (8.0)

This phase deletes the old readers and migration bridges, so the gate applies in full.

- [ ] Extend the forwarding description artifact (R1.0) to cover every function and file about to be deleted, so the deletion is provably complete rather than hopeful.
- [ ] State explicitly why each deletion cannot break payload forwarding, the shadows or any recipe.
- [ ] Obtain Rachid's explicit consent and record it in `LOGS.md`.

- [ ] Add `cloudify deployments` from current manifests.
- [ ] Add `cloudify deployment show <application>[/<flavor>] --name <name>`.
- [ ] Add host-state filters showing physical package, claims, applied version, health and last attempt with secrets masked.
- [ ] Add `cloudify runs` and `cloudify run show <run-id>`.
- [ ] Add `--json` only where it returns the versioned schema unchanged.
- [ ] Inventory every known old desired-input file, registry record and snapshot without printing values.
- [ ] Require explicit application and flavor mapping for every old deployment ID.
- [ ] Move desired inputs to the nested path and successful observations to proved applied facts, and report old snapshots without converting them.
- [ ] Never infer application commit or migrate automatic `output.*` fields.
- [ ] Make migration dry-run first and idempotent.
- [ ] Copy before deleting: each migration leaves the old file in place only until the operator removes it, and the plan names the exact source paths (`deployments/<id>/config.yaml`, `deployments/<id>/runs/*.yaml`, and each old registry `pkgs/<pkg>/config.yaml`) that must be gone before the inventory can report zero.
- [ ] Provide the operator step that removes migrated old source files (a `--delete-source` flag, a documented command, or a documented manual removal) so the zero-inventory precondition is reachable.
- [ ] Verify new read surfaces before deleting an old file.
- [ ] Delete `cloudify deployment migrate`, `cloudify state migrate-registry`, both old-format readers and migration fixtures after the inventory reports zero remaining old artifacts.
- [ ] Strip the migration-only code from `schemas/v1/validate.sh` in the same slice: remove `leak_tokens`, `_trim`, `_store_keys`, `_store_field`, `_snapshot_report`, `_record_report`, `migration_report`, its invocation and inventory assertions inside `validate_fixtures`, the `report` mode with its dispatch, the `report` and report-option lines in `usage()`, and the migration-report sentence in the header comment, leaving schema fixture validation the only mode.
- [ ] Update `schemas/v1/README.md` in the same slice to drop `migration-fixtures/` from Files, the artifact-to-current-format mapping, the migration mapping rules, the cannot-be-derived list, the migration report contract, and the migration lines in Validator command and fixture placeholders.
- [ ] Confirm repo-wide searches find no migration bridge, compatibility flag, old path parser or stale documentation outside append-only history.
- [ ] Run focused migration, read-surface, state, run, event and secret suites.
- [ ] Run `task lint` and the full unit suite.
- [ ] Pass the Phase exit gate (two-host E2E, SPEC review, Technical review) before committing.

## Docs, skills and final acceptance (Phase 9)

Outcome: code, language, docs and operator workflow describe one v2 system and the full project passes independent review.

### Documentation and skills

- [ ] Update README application, deployment, values, context, state, claim, run, event, teardown and migration sections.
- [ ] Keep the "Core Mechanisms" README section (shadow commands, value forwarding, the dispatch context, why the first source wins) accurate and lean; it is the place that stops these rationales being rediscovered.
- [ ] Update `runbooks/README.md` with the final canonical tree, phases, mappings, binding persistence and commit drift.
- [ ] Update package author docs with package instance and explicit secret declaration rules.
- [ ] Update `GLOSSARY.md`: concepts for one path, migration bridge, host mutation lock, package instance and claim, with no compatibility-period or legacy-class entry.
- [ ] Remove every stale registry-as-source, legacy, compatibility and snapshot statement outside append-only history.
- [ ] Propose `AGENTS.md` and `CLAUDE.md` architecture-map changes and obtain Rachid's explicit consent before editing either harness file.
- [ ] Update the `cloudify` and `cloudify-dev` skills.
- [ ] Update `cloudify-pkg-dev` only if recipe declarations changed.
- [ ] Update `HISTORY.md`, append a new ADR if decisions changed, and update `LOGS.md`.

### Test ladder

- [ ] Run L0 shellcheck and syntax checks.
- [ ] Run L1 real-target drivers for context, state, event and runbook phases.
- [ ] Run L2 no-verify mutation on one disposable package and inspect Cloudify's normal log.
- [ ] Run L3 verify with `PKG_VERIFY_TIMEOUT=30`.
- [ ] Push final HEAD.
- [ ] Run only the named integration suites justified by the final diff.
- [ ] Run the full unit suite once on final HEAD.
- [ ] Run one disposable two-host application through install, verify, reconfigure, interruption, shared claim, conflict, first teardown and last teardown.
- [ ] Scan every new artifact and Cloudify log for the fixture secret.
- [ ] Run the full fleet E2E once, only now, as the final exit gate, and record its result in `HISTORY.md`.
- [ ] Teardown every disposable resource and prove policy restoration.

### Mandatory independent completion reviews

- [ ] Spawn a fresh-context SPEC reviewer on a different backend/model to evaluate every shipped behavior against `REDESIGN.md`, ADR-022, ADR-023, schemas and this plan; if no different backend is available, stop for an explicit human waiver.
- [ ] Require the SPEC reviewer to return exactly `PASS` with no actionable feedback.
- [ ] Spawn a separate fresh-context Technical reviewer on another backend/model to evaluate correctness, modularity, security, Bash safety, error propagation, DRY, KISS, maintainability, locking, atomic writes and test quality; if unavailable, stop for an explicit human waiver.
- [ ] Require the Technical reviewer to return exactly `PASS` with no actionable feedback.
- [ ] If either reviewer returns any actionable feedback, fix it, rerun the affected test ladder, then rerun both reviews from fresh contexts.
- [ ] Never declare completion from a conditional pass, a pass with suggestions, or one review only.

### Final closure

- [ ] Confirm `git status --short` is clean.
- [ ] Confirm `PLAN.md` resolves to this plan.
- [ ] Confirm every accepted task is complete and no stale checked box remains.
- [ ] Archive this plan and repoint `PLAN.md` only after the full E2E and both independent reviews pass.
- [ ] Declare full completion only after all four facts hold: tests green, disposable resources removed, SPEC review `PASS`, Technical review `PASS`.

## Deferred work

- Multi-operator writes until a coordination service is chosen.
- Secret-aware backup and replication.
- ivps node and instance immutable IDs, provider, origin, address, role, gateway and engine redesign.
- Event replay as executable commands.
- Automatic host rename migration.

Deferred work is not a blocker and must not enter this project without a new ADR and explicit consent.
