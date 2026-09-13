# State model v2 recovery and completion plan

Goal: repair the committed Phase 2 and Phase 3 foundations, then implement `REDESIGN.md` through completion without carrying rejected code or compatibility layers.

Decision: ADR-022.

This plan supersedes `plans/archived/state-model-v2-attempt1.md`.

The archived plan is implementation history only.

Its completed boxes do not authorize work and must not be copied here.

## Current truth

- [x] Phase 1 schemas, identity rules, fixtures and defect proofs are retained.
- [x] Phase 2 and Phase 3 commits are retained as a repairable baseline, not accepted as specification-complete.
- [x] Uncommitted Phase 4A code was archived under `~/tmp/cloudify-phase4a-rejected-20260913/` and removed from the repository.
- [x] The rejected `plans/state-model-v2-phase4-design.md` was removed.
- [x] The contradictory `plans/state-model-v2-phase2-design.md` was archived as `plans/archived/state-model-v2-phase2-attempt-design.md` and its live citations repointed.
- [x] No Phase 4 implementation or design is accepted.
- [x] Rachid directed that Cloudify ship one v2 path, with no compatibility switches, dual readers or legacy discovery.
- [x] The only temporary exceptions are one-shot migration commands for old desired inputs, registry records and snapshots; each is deleted after the inventory reports zero old artifacts.
- [x] `lib/shadows/` and `lib/shadow.sh` remain untouched unless a new description, non-breakage argument and explicit consent allow a specific change.

## Authority order

When two documents disagree, use this order:

1. `AGENTS.md` and `~/AGENTS.md`.
2. ADR-023 for the one-path and migration decision, then ADR-022 for the state model.
3. `REDESIGN.md`.
4. `GLOSSARY.md` for live concept definitions.
5. `schemas/v1/*.schema.json` and `schemas/v1/identity.md`.
6. `plans/state-model-v2-description.md` for current Bash invariants.
7. `plans/state-model-v2-non-breakage.md`, except its compatibility clauses superseded by section 9.
8. This plan.
9. The two archived attempts (`plans/archived/state-model-v2-attempt1.md` and `plans/archived/state-model-v2-phase2-attempt-design.md`) and the rejected patch, as evidence only.

No implementation may weaken a higher authority silently.

A required design change needs a new append-only ADR and Rachid's consent before code.

## Mandatory execution rules

- [ ] Never mark a task complete from a subagent report alone; the lead agent verifies the file, focused tests and diff.
- [ ] Never mark an entire phase complete with a bulk checkbox replacement.
- [ ] One red test, minimum green implementation, refactor, then the next red test.
- [ ] Every slice ends with focused tests and shellcheck before commit.
- [ ] Full unit suite runs only at recovery and phase boundaries.
- [ ] Run tests in the background into `results/<name>.tap` and poll with plain `tail`.
- [ ] Read Cloudify's normal `/tmp/cloudify/logs/<timestamp>.log`; do not create custom diagnostic logs or grep test output.
- [ ] Do not use integration or E2E as a debugger.
- [ ] Run a blast-radius-focused integration or partial E2E only after L0 through L3 are green and predict its result first.
- [ ] Run the full disposable E2E only as the final exit gate.
- [ ] Push before every test whose remote host pulls from GitHub.
- [ ] No compatibility flags, fallback readers, dual writers, legacy path discovery or superseded command aliases.
- [ ] A temporary migration reader must be the sole caller of the old format and must have a deletion task in this plan.
- [ ] Deleting a migration reader or its fixtures must leave the surviving gates (especially `bash schemas/v1/validate.sh`) passing; name the replacement gate in the same task.
- [ ] No code commit while a SPEC or Technical reviewer has actionable feedback on that slice.
- [ ] When a review returns actionable feedback, fix the slice, rerun its focused tests and shellcheck, then request that review again from a fresh context.
- [ ] `git status --short` is clean at every committed boundary.

Test levels are fixed: L0 is shellcheck plus syntax; L1 is a real-target driver without dispatch; L2 is one no-verify mutation; L3 is verify with `PKG_VERIFY_TIMEOUT=30`; L4 is the scoped bats acceptance harness.

## Recovery Gate R0: clean baseline

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
- [ ] Commit and push the clean recovery baseline.

## Recovery Gate R1: make Phase 2 one real resolution

Outcome: one private dispatch context contains everything every later consumer needs, and no consumer reopens a value source.

### R1.1 Freeze the context contract before code

- [ ] Add `schemas/v1/dispatch-context.schema.json` and valid and invalid fixtures.
- [ ] Add `dispatch-context` to `schemas/v1/validate.sh`'s artifact list and update `schemas/v1/README.md` file list, field lists, validator description and `schema_version` rule for the fifth schema.
- [ ] Use actual JSON for the context so the schema and the file cannot disagree, with `schema_version: 1` like every other machine-owned artifact.
- [ ] Use local `jq` as the one parent-side JSON encoder and validator; require it on the operator machine before state work, and make no remote bootstrap or remote-host dependency change.
- [ ] Include dispatch identity, resolved target identity and address, application commit, run ID, stable step ID, package instance and phase.
- [ ] Fields without a producer stay null: run ID until Phase 6, stable step ID outside a runbook, and application commit outside an application run; package instance is the specified `default` until explicit multi-instance support lands.
- [ ] Include a separate declared-value view for the top-level package and every dependency that may execute.
- [ ] For each name include declaration kind, source label, source form, resolved runtime form and secret classification origin.
- [ ] Define and test the exact projections from each context value into `package-state.applied.values`, `package-state.last_attempt.requested` and event `values` before any writer uses them.
- [x] Secret classification origin is exactly `explicit`, `heuristic` or `none`; the stale `legacy-heuristic` term is removed from schemas, fixtures and docs.
- [ ] Permit resolved plaintext transiently in both this 0600 ephemeral context and collector shell exports, as `REDESIGN.md` requires; neither channel may be removed before payload execution.
- [ ] Keep literal secret plaintext out of logs, debug output, state, runs and events.
- [ ] Validate the context before payload construction and before any mutation.
- [ ] Obtain a fresh SPEC review and Technical review of this contract, each returning `PASS` with no actionable feedback.

### R1.2 Replace the incomplete context

- [ ] Build each package view once from the source ladder at context creation.
- [ ] Preserve install precedence exactly as `REDESIGN.md` states, strongest first: caller or step environment, deployment desired inputs, application defaults, package defaults, global defaults, recipe defaults.
- [ ] Resolve application input mappings into the relevant package view only, never into one shared ambient namespace.
- [ ] Preserve separate defaults when two packages use the same variable name differently.
- [ ] Preserve file-store secret reference resolution and caller-environment literal timing.
- [ ] Compute literal-secret digests while the resolved plaintext is in the private context.
- [ ] Delete `_cloudify_registry_context_raw`, the committed store re-opener, and any equivalent helper that reopens a value store after context creation; `cloudify_context_raw_value` existed only in the rejected patch and is already gone.
- [ ] Make preflight, the `envsubst` allow-list names, registry observation, snapshot writer and future state/event writers consume this context only.
- [ ] Never read a resolved value back from the context to build the payload; values still flow resolver shell exports to one envsubst pass to single-quoted remote exports.
- [ ] Keep collector exports in the calling shell and never capture them with command substitution.
- [ ] Keep the payload on stdin and keep context paths and values off argv.
- [ ] Remove the context only after the parent has written every result consumer.

### R1.3 Prove the root defect is gone

- [ ] Create a context, then mutate or trash every source file; payload, registry and snapshot must still use the original context answer.
- [ ] Give a top-level package and dependency the same name with different package defaults; each package view must keep its own answer.
- [ ] Cover environment, desired input, application default, package default, global default and recipe default independently.
- [ ] Cover required, optional and declared-default names.
- [ ] Cover plain, escaped-at, backend reference, multiline, spaces, quotes, colons and shell metacharacters.
- [ ] Assert no fixture secret appears in debug output or any persisted artifact.
- [ ] Prove the corrected resolution keeps payload and registry bytes identical to the pre-deletion goldens; treat any changed byte as a defect to explain, not a new golden to accept.
- [ ] Run focused context, vars, remote, registry, runbook, replay and router suites.
- [ ] Run `task lint` and the full unit suite.
- [ ] Obtain fresh SPEC and Technical reviews of the Phase 2 repair, both `PASS` with no actionable feedback.
- [ ] Commit and push only after both reviews pass.

## Recovery Gate R2: audit and trim Phase 3

Outcome: application identity, desired inputs, phase selection and manifests match the specification with one implementation each.

### R2.1 Manifest and state-root audit

- [ ] Prove every `manifest.json` is actual JSON that validates against `schemas/v1/deployment-manifest.schema.json` before atomic replacement.
- [ ] Prove component validation happens before any path creation.
- [ ] Prove manifest writes take one deployment lock and no host lock is held at the same time.
- [ ] Prove lifecycle ordering: `applying` before mutation, `active` after install plus verify, `degraded` after observed failure.
- [ ] Prove a killed writer remains discoverable without fabricating a run record.
- [ ] Keep applied package values out of the manifest.
- [ ] Create a manifest only from an application run whose current commit is proved; old desired-input migration never fabricates a manifest or application commit.

### R2.2 Application and runbook audit

- [ ] Keep only `runbooks/<application>/<flavor>/runbook.md` discovery.
- [ ] Keep only nested desired inputs at `deployments/<application>/<flavor>/<deployment>/values.yaml`.
- [ ] Keep existing `cloudify deployment migrate` as the sole reader of the old single-ID desired-input file and mark it for deletion in Phase 8; Phase 4.7 introduces `cloudify state migrate-registry` as the sole old-registry reader.
- [ ] Prove `inputs:` and `map:` use one parser and mappings feed only the relevant package context view.
- [ ] Prove bare `app run` selects install then verify and can never select teardown through `--yes`.
- [ ] Prove selected-phase preflight checks only the selected phases.
- [ ] Prove target bindings persist and ordinary reruns cannot silently rebind them.
- [ ] Prove direct package commands bypass application manifests as specified.
- [ ] Delete dead aliases, duplicate parsers, duplicate path builders and stale compatibility language.
- [ ] Reduce `lib/runbooks.sh`, `lib/state.sh`, `lib/context.sh`, `lib/deployments.sh` and `lib/vars.sh` where the same fact is parsed or formatted more than once; inline each duplicate into one existing parser rather than adding another abstraction layer.
- [ ] Replace the all-zeros `_CLOUDIFY_MANIFEST_NULL_COMMIT` sentinel with real `null` in the manifest and run records, now that the schemas allow it, and make the shell manifest validator accept null only with `development_override: true`.

### R2.3 Phase 3 gate

- [ ] Run focused runbook, replay, target, deployment, state, vars and router suites.
- [ ] Run a real L1 driver in `cloudai:cloudify` without dispatch.
- [ ] Run `task lint` and the full unit suite.
- [ ] Obtain a fresh SPEC review against `REDESIGN.md` and schema fixtures, returning `PASS` with no actionable feedback.
- [ ] Obtain a fresh Technical review for DRY, KISS, data flow, error paths and lock ordering, returning `PASS` with no actionable feedback.
- [ ] Commit and push only after both reviews pass.

## Gate R3: fresh Phase 4 design before code

Outcome: a reviewed Phase 4 design replaces the rejected flat-state and unsafe-stream attempt.

- [ ] Write a new `plans/state-model-v2-phase4-design.md` from `REDESIGN.md`, the corrected context schema and the package-state/event schemas; do not copy the rejected patch.
- [ ] State is actual JSON and validates against `schemas/v1/package-state.schema.json` before atomic replacement.
- [ ] No package state writer lands before the immutable event writer exists.
- [ ] Tighten the package-state schema before implementation so every new applied, attempt, health and claim object carries a non-null event ID; migration also emits its own event.
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
- [ ] Reconcile results against every precomputed package view and fail closed on an unexpected package.
- [ ] Freeze lock, state, event and result-frame tests before implementation.
- [ ] Obtain independent SPEC and Technical design reviews, both `PASS` with no actionable feedback.
- [ ] Obtain explicit Rachid consent for the reviewed Phase 4 design before code.

## Phase 4: physical package state, events and claims

Outcome: one physical installation is represented once, every mutation has an immutable event, and one deployment cannot break another.

### 4.1 State and event substrate

- [ ] Add collision-resistant run and event IDs without a new runtime dependency.
- [ ] Write immutable Cloudify-owned event files under the Cloudify state root.
- [ ] Validate every event against `schemas/v1/event.schema.json` before create.
- [ ] Create one JSON package-state file per host, package and package instance.
- [ ] Validate next state before atomic replacement.
- [ ] Create the event first, then replace state with revision plus one and that event ID.
- [ ] Detect and report an event whose resulting revision is absent from state and state pointing to a missing event.
- [ ] Never infer remote rollback from a local write failure.

### 4.2 Package instance and host identity

- [ ] Default package instance to `default`.
- [ ] Reject a non-default instance unless the recipe explicitly declares support.
- [ ] Include package instance in context views, result frames, state subjects, claims and events; the host lock remains keyed only by durable host identity.
- [ ] Use ivps node or instance identity for inventory hosts.
- [ ] Reject durable external-host state until its SSH host key is accepted in Phase 5.

### 4.3 Host lock and result channel

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
- [ ] Once package state is written here, stop the runtime registry observation writer: the v2 package state becomes the single record of what landed, and the old registry record-write path plus its tests are deleted rather than kept beside it.
- [ ] Keep only the migration command's registry reader until Phase 8 deletes it.

### 4.4 Phase-specific resolution

- [ ] Install uses the corrected Phase 2 context and creates a missing physical instance or compatible claim.
- [ ] Reconfigure uses caller or desired inputs above the last successful applied source forms and defaults below them.
- [ ] Verify and teardown seed from last successful applied source forms.
- [ ] A failed last attempt never seeds another phase.
- [ ] A literal secret represented by digest only must be resupplied by caller or desired inputs and match before verify or teardown.
- [ ] Changed defaults never silently alter an existing claim.

### 4.5 Claims and adoption

- [ ] Store claims inside the physical package-state JSON.
- [ ] Key each claim by application, flavor, deployment, stable step ID and package instance.
- [ ] Compare non-secrets by source form, references by reference and literal secrets by digest.
- [ ] Add a claim only after successful compatible installation or adoption.
- [ ] Install over an existing compatible claim is a no-op followed by verify.
- [ ] Explicit differing input fails before mutation and directs the operator to reconfigure or upgrade.
- [ ] An unclaimed compatible package receives a claim without mutation.
- [ ] A differing unclaimed package requires `--adopt` and configure support.
- [ ] Never print either side of a secret conflict.

### 4.6 Uninstall protection and failure state

- [ ] Release every claim owned by the deployment, including dependency claims.
- [ ] Skip physical uninstall while another claim remains.
- [ ] Uninstall only when the last claim is released and the teardown phase names the package.
- [ ] Leave an unclaimed dependency installed unless teardown names it.
- [ ] Put claim checks before recipe code.
- [ ] Preserve `applied` on every failed install, reconfigure, verify or uninstall.
- [ ] Record failed `last_attempt` and degraded or unknown health.
- [ ] Add no claim after an unsuccessful first install.
- [ ] Keep an existing claim after unsuccessful reconfigure.

### 4.7 Migration and Phase 4 gate

- [ ] Add temporary `cloudify state migrate-registry` as the sole old-registry reader.
- [ ] Map only facts the registry proves; write `application_commit: null` and a migration event when the old record cannot prove provenance.
- [ ] Make migration dry-run first, idempotent and value-safe.
- [ ] Run focused package API, context, state, event, registry, router and runbook suites.
- [ ] Run one real shared-dependency case only after L0 through L3 pass.
- [ ] Run `task lint` and the full unit suite.
- [ ] Obtain fresh SPEC and Technical implementation reviews, both `PASS` with no actionable feedback.
- [ ] Commit and push only after both reviews pass.

## Phase 5: explicit secrets, ephemeral outputs and SSH identity

Outcome: classification is enforceable, no new artifact copies plaintext secrets or automatic outputs, and external-host state has durable identity.

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
- [ ] Obtain fresh SPEC and Technical reviews, both `PASS` with no actionable feedback.

## Phase 6: run lifecycle and repair detection

Outcome: runs are durable, interruptions and event-state gaps are reportable, and events remain audit rather than replay commands.

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
- [ ] Obtain fresh SPEC and Technical reviews, both `PASS` with no actionable feedback.

## Phase 7: pinned provenance, safe teardown and upgrade

Outcome: teardown releases only owned resources and today's branch tip is never presented as yesterday's application.

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
- [ ] Obtain fresh SPEC and Technical reviews, both `PASS` with no actionable feedback.

## Phase 8: read surface, one-shot migration and deletion of bridges

Outcome: operators inspect state through commands, all known old data is migrated once, and no migration or old-format code remains.

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
- [ ] Obtain fresh SPEC and Technical reviews, both `PASS` with no actionable feedback.

## Phase 9: docs, skills and final acceptance

Outcome: code, language, docs and operator workflow describe one v2 system and the full project passes independent review.

### Documentation and skills

- [ ] Update README application, deployment, values, context, state, claim, run, event, teardown and migration sections.
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
- [ ] Run the full E2E once, only now, as the exit gate.
- [ ] Teardown every disposable resource and prove policy restoration.

### Mandatory independent completion reviews

- [ ] Spawn a fresh-context SPEC reviewer on a different backend/model to evaluate every shipped behavior against `REDESIGN.md`, ADR-022, ADR-023, schemas and this plan; if no different backend is available, stop for an explicit human waiver.
- [ ] Require the SPEC reviewer to return exactly `PASS` with no actionable feedback.
- [ ] Spawn a separate fresh-context Technical reviewer on another backend/model to evaluate correctness, security, Bash safety, error propagation, DRY, KISS, maintainability, locking, atomic writes and test quality; if unavailable, stop for an explicit human waiver.
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
