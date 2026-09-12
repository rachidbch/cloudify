# State model v2 implementation plan

Goal: implement `REDESIGN.md` without breaking remote forwarding, shadow commands, direct package commands, current deployments, or secret handling.

Decision: ADR-022.

This plan supersedes `plans/archived/state-model-implementation-v1.md`.

No task under `lib/`, the `cloudify` router, package runtime behavior, or ivps may start until its gate is complete.

## Global gates

### G0: design freeze

- [x] Record the revised design in `REDESIGN.md`.
- [x] Define application and deployment identity as separate validated tuple components.
- [x] Keep deployment desired inputs as a distinct source.
- [x] Separate physical package state from deployment claims.
- [x] Define phase-specific value resolution.
- [x] Define applied state separately from the last attempt.
- [x] Make events audit records rather than a replay engine.
- [x] Defer unrelated ivps identity, provider, address, role, and engine changes.
- [x] Supersede ADR-021 with ADR-022 without editing ADR-021.
- [x] Update `GLOSSARY.md`, `HISTORY.md`, `LOGS.md`, and the relevant ROADMAP pointers.
- [x] Keep the current `AGENTS.md` registry rule as runtime truth until v2 applied state exists and a separately consented harness update lands.

### G1: CRITICAL GATE description

- [x] Spawn a read-only subagent whose only mission is to describe Cloudify's brittle Bash mechanisms end to end.
- [x] Write the accepted description to `plans/state-model-v2-description.md`.
- [x] Trace package declarations through `.remote-vars`, every value source, first-write-wins claiming, and caller-environment preservation.
- [x] Trace router parsing through target resolution, background dispatch metadata, local dispatch, and remote dispatch.
- [x] Trace `declare -f` payload extraction, placeholder insertion, the explicit `envsubst` allow-list, single-quoted remote references, stdin transport, and remote bootstrap.
- [x] Trace each shadow command and state the invariants recipes depend on.
- [x] Trace runbook parsing, preflight, target binding, phase exports, step execution, output ingestion, failure handling, snapshots, and replay.
- [x] Trace dependency execution through `pkg_depends`, including which packages the router can and cannot observe.
- [x] Include file and line references plus minimal shell probes for every load-bearing claim.
- [x] Review the description against `AGENTS.md` and `cloudify-dev` before accepting it.

### G2: non-breakage argument

- [x] Write `plans/state-model-v2-non-breakage.md` after G1.
- [x] State the preserved forwarding invariants for every implementation phase.
- [x] State whether each phase touches `remote.sh`, the router, shadows, package APIs, runbooks, registry storage, or ivps.
- [x] Prove that collector exports remain the value channel and are never captured through command substitution.
- [x] Prove that payloads remain on stdin and secrets remain off argv.
- [x] Prove that the explicit `envsubst` allow-list contains exactly the resolved dispatch names.
- [x] Prove that remote-side single-quoted exports preserve literal expansion timing.
- [x] Prove that direct package install, configure, verify, and uninstall retain their current signatures, with claim protection as the one approved safety change.
- [x] Prove that shadow command lookup and behavior are byte-identical unless a separately consented change says otherwise.
- [x] Treat SSH host-key pinning as an explicit `remote.sh` change and include its transport non-breakage argument before Phase 5.
- [x] Prove that old state remains readable before any writer switches formats.
- [x] List rollback boundaries and the files restored by each rollback.

### G3: human consent

- [ ] Present G1, G2, this plan, migration risks, and the proposed first red test to Rachid.
- [ ] Obtain explicit consent before the first code or package-runtime change.
- [ ] Record the consent and exact approved scope in `LOGS.md`.
- [ ] Treat scope expansion as a new consent gate.

### G4: working branch and baseline

- [ ] Push the current documentation commits so remote test hosts can pull them.
- [ ] Create one feature branch for the first approved implementation slice.
- [ ] Confirm `git status --short` is clean before each red test.
- [ ] Record current `task lint` and focused unit-suite baselines in `LOGS.md`.
- [ ] Run tests only inside `cloudai:cloudify`.
- [ ] Use L0 through L4 as defined in the `cloudify-dev` skill, with the full bats harness only at phase boundaries.

## Phase 1: characterize the defect and freeze schemas

Outcome: executable tests prove the duplicate-resolution defect, and versioned schemas plus migration fixtures are agreed before writers change.

### 1.1 Reproduce one dispatch resolving two answers

- [ ] Add one failing integration-level test that gives one declared value conflicting deployment, package, global, and caller sources.
- [ ] Assert the forwarded remote value is the caller value.
- [ ] Assert the current snapshot and registry paths record different answers before the fix.
- [ ] Keep the test focused on one package and one target.
- [ ] Capture no literal secret in test output.
- [ ] Confirm the test fails for the intended duplicate-walk reason.

### 1.2 Characterize first-install shared inputs

- [ ] Add a test with two packages on two targets consuming one deployment input.
- [ ] Assert both first installs receive the value before either package has state.
- [ ] Add a package-variable mapping case with one application input mapped to two package variable names.
- [ ] Assert package defaults remain independent when no mapping exists.

### 1.3 Freeze identity rules

- [ ] Specify validation for application, flavor, and deployment-name components.
- [ ] Cover `default` flavor and deployment-name defaults.
- [ ] Cover two applications using deployment name `default` without collision.
- [ ] Cover rejection of empty components, dot components, separators, control characters, and traversal.
- [ ] Cover unambiguous CLI rendering and parsing of the tuple.

### 1.4 Freeze JSON schemas

- [ ] Add schema fixtures for the deployment manifest, package state, run, and event.
- [ ] Include `schema_version: 1` in every machine-owned artifact.
- [ ] Keep one file per subject and avoid nested documents that Bash cannot update safely.
- [ ] Define package state fields for revision, applied, last attempt, health, and active claims.
- [ ] Define event fields without raw command output or literal secret values.
- [ ] Define explicit secret declaration metadata, reference comparison, and literal-secret digest fields before claim schemas depend on them.
- [ ] Define run writer identity and interrupted-run classification fields.
- [ ] Validate every fixture with `jq -e`.
- [ ] Add invalid-schema cases that fail closed before mutation.

### 1.5 Build migration fixtures

- [ ] Add fixtures for the current deployment `config.yaml`.
- [ ] Add fixtures for current registry `config.yaml` records in node, instance, and external-host buckets.
- [ ] Add fixtures for successful and failed run snapshots.
- [ ] Include secret reference, literal secret, multiline base64, target binding, and same-second snapshot cases.
- [ ] Define an inventory-only migration report that prints names and paths but no values.

### Phase 1 non-breakage argument

- [ ] Confirm this phase changes tests, schemas, and documentation only.
- [ ] Confirm no payload, shadow, package API, or on-disk writer behavior changes.

### Phase 1 gate

- [ ] Run L0 for added shell tests and fixtures.
- [ ] Run only the new characterization tests and confirm the intended red cases.
- [ ] Review schemas and migration mapping before implementation.

## Phase 2: one dispatch context and one value resolution

Outcome: one resolved context feeds forwarding and records while current deployment inputs and snapshots remain supported.

### 2.1 Add a pure source-form resolver

- [ ] Introduce one resolver for a single `(deployment, target, top-level package, package instance, phase)` dispatch.
- [ ] Expand the static dependency graph before resolution.
- [ ] Build a separate declared-value view for the top-level package and every dependency that may execute.
- [ ] Keep the legacy single deployment ID opaque in Phase 2 and route it only through legacy readers and commands.
- [ ] Pass the resolved target triple into the resolver explicitly.
- [ ] Return value names, source forms, source labels, required or optional status, and secret metadata.
- [ ] Implement a backward-compatible explicit secret marker in `.remote-vars` and application input declarations.
- [ ] Compute literal-secret digests inside the private context without logging or persisting plaintext outside approved deployment inputs.
- [ ] Preserve current first-write-wins precedence for direct package commands.
- [ ] Add application defaults and deployment desired inputs without deleting current stores.
- [ ] Reject framework-owned names before context materialization.
- [ ] Reject malformed or failed secret references before dispatch.

### 2.2 Materialize the private dispatch context

- [ ] Write the context to a mode-0600 file under `CLOUDIFY_TMP`.
- [ ] Keep resolved runtime literals separate from source forms.
- [ ] Ensure cleanup occurs on success, ordinary failure, signal, and parent exit.
- [ ] Ensure background children cannot delete a sibling dispatch context.
- [ ] Ensure context paths and values never enter the remote command argv.

### 2.3 Feed the remote payload from the context

- [ ] Preserve `declare -f` template extraction.
- [ ] Preserve placeholder insertion and single-quoted package exports.
- [ ] Build the `envsubst` allow-list from context value names only.
- [ ] Preserve the existing fixed framework allow-list.
- [ ] Keep payload transport through a private file redirected to SSH stdin.
- [ ] Replace payload debug rendering with names, source labels, and redaction status.
- [ ] Verify no secret value appears when `DEBUG=true`.

### 2.4 Remove the second value walk

- [ ] Change the registry writer to consume the completed dispatch context.
- [ ] Delete or retire `_cloudify_registry_raw_var` only after all callers use the context.
- [ ] Make snapshots consume the same source-form context during the compatibility period.
- [ ] Make preflight invoke the same resolver in non-mutating mode.
- [ ] Prove preflight and execution select the same source for every declared name.

### 2.5 Preserve current lifecycle behavior and freeze the v2 phase interfaces

- [ ] Implement current install and configure precedence from existing deployment inputs and defaults through the single context.
- [ ] Keep the current registry observation-only and out of the generic value ladder.
- [ ] Define resolver inputs for future applied-state seeding without activating them before v2 physical state exists.
- [ ] Add failing specifications for reconfigure, verify, teardown, existing-claim install, and adoption that Phase 4 will turn green.
- [ ] Keep current direct package and legacy runbook behavior unchanged in this phase.

### Phase 2 non-breakage argument

- [ ] Map every modified function against the G1 forwarding description.
- [ ] Show that collector exports still occur in the current shell.
- [ ] Show that package recipes receive the same environment for existing direct commands.
- [ ] Show that no shadow file or command lookup changes.
- [ ] Show that old deployment config and package config files retain their precedence for existing commands.

### Phase 2 tests

- [ ] Red and green one source-precedence case at a time.
- [ ] Cover local and remote dispatch.
- [ ] Cover dependency declarations and rightmost package precedence.
- [ ] Cover unset required, optional, and recipe-default declarations.
- [ ] Cover literal, escaped-at, base64, and backend-reference values.
- [ ] Cover quotes, spaces, shell metacharacters, colons, and multiline values.
- [ ] Assert the payload and all logs contain no test secret.
- [ ] Run L1 with a real target-side phase driver.
- [ ] Run L2 and L3 on one harmless fixture package.
- [ ] Run focused vars, remote-vars, registry-write, runbook, replay, and router suites.
- [ ] Run `task lint` and `task test-unit` once at the phase boundary.

### Phase 2 rollback

- [ ] Keep old readers and snapshot format available behind one compatibility switch.
- [ ] Document how to restore the old collector and writer without transforming data backward.

## Phase 3: application identity, deployment inputs, manifests, and phases

Outcome: applications and named deployments have collision-free identity, durable bindings, and safe phase selection.

### 3.1 Migrate the runbook tree

- [ ] Support `runbooks/<application>/<flavor>/runbook.md` as the canonical path.
- [ ] Keep `runbooks/<application>/<flavor>.md` discoverable for one compatibility period.
- [ ] Derive application identity from the canonical path rather than a deployment field in front matter.
- [ ] Remove required `deployment:` front matter only after dual-format tests pass.
- [ ] Keep target declarations and stable step IDs.
- [ ] Add application input declarations and explicit package-variable mappings.
- [ ] Migrate `runbooks/xfce-guacamole/disposable.md` to the canonical tree and add explicit phases to every `run` and `human-gate` step.

### 3.2 Add application CLI commands

- [ ] Add `cloudify app run <application>[/<flavor>] [--name <name>]`.
- [ ] Add `cloudify app run <application>[/<flavor>] [--name <name>]` for install and application verification.
- [ ] Reserve but do not route `app reconfigure`, `app verify`, or `app teardown` until v2 physical state and claims land in Phase 4.
- [ ] Export `CLOUDIFY_APPLICATION`, `CLOUDIFY_FLAVOR`, and `CLOUDIFY_DEPLOYMENT_NAME` to child dispatches.
- [ ] Require migration to receive the explicit application and flavor before mapping a legacy `CLOUDIFY_DEPLOYMENT` ID.
- [ ] Keep existing `cloudify deployment run` and replay commands as compatibility aliases until migration ends.
- [ ] Keep direct package commands unchanged.
- [ ] Print the full application reference and deployment name in every plan and error.

### 3.3 Move desired inputs without deleting them

- [ ] Add the nested deployment input path keyed by application, flavor, and deployment name.
- [ ] Add read-through from the old single-ID deployment store.
- [ ] Require an explicit application reference when migrating an old deployment ID.
- [ ] Write new values only to the new path after migration confirmation.
- [ ] Preserve `--stdin` and `--file` secret input paths.
- [ ] Keep mode 0700 directories and mode 0600 files.
- [ ] Add one Cloudify state-root helper using `${XDG_STATE_HOME:-$HOME/.local/state}/cloudify`.
- [ ] Route manifests, runs, events, and external-host state through that helper.
- [ ] Keep the existing Cloudify configuration helper for defaults and desired inputs.

### 3.4 Add the deployment manifest

- [ ] Add one local `flock` per deployment manifest before the first manifest writer lands.
- [ ] Create the manifest atomically under that lock before the first mutating step.
- [ ] Record application identity, commit, deployment name, target bindings, lifecycle status, and last run and event IDs.
- [ ] Keep applied package values out of the manifest.
- [ ] Use recorded bindings for reconfigure, verify, and teardown.
- [ ] Reject silent rebinding while active claims exist.
- [ ] Add an explicit target migration path but defer automatic resource movement.

### 3.5 Add phase parsing and selection

- [ ] Accept `phase=install|reconfigure|verify|teardown` on runbook steps.
- [ ] Apply the documented default phase for each typed step.
- [ ] Require `phase=` on `run` and `human-gate` steps in canonical runbooks.
- [ ] Keep every legacy-path runbook executable only through the legacy engine during compatibility and warn when `run` or `human-gate` lacks a phase.
- [ ] Reject unknown phases and contradictory type-phase combinations before execution.
- [ ] Make a bare app run select install then verify only.
- [ ] Make preflight inspect only selected phases.
- [ ] Ensure `--yes` cannot cause teardown selection.
- [ ] Preserve document order inside each selected phase.

### 3.6 Define manifest lifecycle during snapshot compatibility

- [ ] Set manifest status to `applying` before mutation.
- [ ] End successful install plus verify as `active`.
- [ ] Mark observed failures `degraded`.
- [ ] Link the compatibility snapshot until Phase 6 introduces run lifecycle records.
- [ ] Defer stale-run classification to Phase 6 rather than fabricating a partial run record here.

### Phase 3 non-breakage argument

- [ ] Show that legacy runbooks and deployment commands remain readable and executable.
- [ ] Show that direct package dispatch bypasses application manifests exactly as before.
- [ ] Show that phase filtering changes only runbook selection, not package or shadow execution.
- [ ] Show that existing target grammar and resolver behavior remain unchanged.

### Phase 3 tests

- [ ] Cover default and named deployments for two applications without collision.
- [ ] Cover canonical and legacy runbook paths.
- [ ] Cover manifest creation before the first step.
- [ ] Kill a run between steps and assert an interrupted record remains discoverable.
- [ ] Cover target binding reuse and active-claim rebinding refusal.
- [ ] Cover every default phase mapping.
- [ ] Prove a normal run and `--yes` never execute teardown.
- [ ] Cover selected-phase preflight so teardown-only values do not block install.
- [ ] Run the focused runbook, replay, target, deployment, vars, and router suites.
- [ ] Run `task lint` and `task test-unit` at the phase boundary.

## Phase 4: physical package state and deployment claims

Outcome: Cloudify models one physical installation once and prevents one deployment from breaking another.

### 4.1 Introduce package-instance identity

- [ ] Default every package dispatch to package instance `default`.
- [ ] Define the declaration and CLI path for recipes that support multiple independent instances.
- [ ] Reject a non-default instance for recipes that do not declare support.
- [ ] Include package-instance identity in locks, contexts, state, claims, and events.

### 4.2 Serialize host mutation before state writers land

- [ ] Add one host mutation `flock` for every package dispatch to that host.
- [ ] Acquire it before remote execution and hold it through every top-level and dependency result commit.
- [ ] Add no package-level nested locks.
- [ ] Bound lock waits and print holder metadata on timeout.
- [ ] Release the host mutation lock before acquiring the deployment manifest lock.

### 4.3 Write the physical package state

- [ ] Place one state file per host, package, and package instance.
- [ ] Migrate successful legacy registry records into the `applied` section.
- [ ] Store last successful source-form values, package version, application commit, and time.
- [ ] Keep event ID fields nullable until Phase 6 introduces immutable events.
- [ ] Store `last_attempt` separately.
- [ ] Store verification health separately.
- [ ] Increment the revision only under the host mutation lock.

### 4.4 Activate phase-specific applied-state resolution

- [ ] Implement reconfigure precedence with deployment inputs above last successful applied values and defaults below them.
- [ ] Implement verify from applied values by default.
- [ ] Require literal secrets absent from applied state to be resupplied by caller or deployment input and verify each digest before verify.
- [ ] Implement teardown from applied values.
- [ ] Require literal secrets absent from applied state to be resupplied by caller or deployment input and verify each digest before teardown.
- [ ] Ensure a failed last attempt never seeds a later reconfigure or teardown.
- [ ] Make install on an existing claim a no-op followed by verification.
- [ ] Fail install when explicit caller or deployment inputs differ from applied state and direct the operator to reconfigure or upgrade.
- [ ] Ensure changed defaults do not silently alter an existing claim.
- [ ] Route `app reconfigure`, `app verify`, and `app teardown` only after these paths pass their focused tests.

### 4.5 Add active claims

- [ ] Store active claims inside the physical package state to avoid a second transactional state file.
- [ ] Key each claim by application, flavor, deployment name, and stable step ID.
- [ ] Define compatible as matching package identity, package instance, applied recipe commit or declared version, and every configuration-affecting value.
- [ ] Compare non-secrets by source value, secret references by reference, and literal secrets by the Phase 2 digest.
- [ ] Add a claim after successful compatible installation.
- [ ] Keep an existing compatible package installed when another deployment claims it.
- [ ] Allow an unclaimed compatible physical package to receive a claim without mutation.
- [ ] Require `--adopt` before changing an unclaimed physical package to satisfy differing explicit inputs.
- [ ] Run configure during adoption when supported and add the claim only after success.
- [ ] Fail adoption for a package without configure support until the operator explicitly removes or reconciles it.
- [ ] Reject an incompatible value set before any package mutation.
- [ ] Name every conflicting deployment and differing non-secret value name in the error.
- [ ] Never print either side's secret content.

### 4.6 Protect uninstall

- [ ] Release every claim owned by the calling deployment, including dependency claims without authored uninstall steps.
- [ ] Skip physical uninstall while another active claim remains.
- [ ] Leave an unclaimed dependency installed unless the pinned teardown phase explicitly names it.
- [ ] Uninstall only when the last claim is released and the teardown step asks for it.
- [ ] Add an explicit destructive override with confirmation.
- [ ] Log every displaced claim without values during compatibility and emit the immutable destructive event after Phase 6 lands.

### 4.7 Observe dependencies accurately

- [ ] Add a remote-to-parent result channel listing every package actually attempted by `pkg_depends`.
- [ ] Include success, failure, package instance, and dependency parent without exposing values.
- [ ] Resolve each reported package's state values from its precomputed per-package dispatch-context view.
- [ ] Fail the state commit and mark the run degraded when runtime execution reports a dependency absent from the precomputed graph.
- [ ] Update state and claims for successful dependencies, not only CLI packages.
- [ ] Keep the package API signature stable for all recipes.
- [ ] Prove a parent force or clear-data flag still does not cascade into dependencies.

### 4.8 Handle failed and partial mutations

- [ ] On failure, preserve the last successful `applied` section.
- [ ] Record the failed attempt and mark health `degraded` or `unknown`.
- [ ] Do not add a new claim for an unsuccessful first install.
- [ ] Keep an existing claim after an unsuccessful reconfigure.
- [ ] Require verify or explicit repair before claiming a partially observed host is healthy.

### Phase 4 non-breakage argument

- [ ] Show that packages still call the same package API and shadow commands.
- [ ] Show that claim checks happen before uninstall reaches recipe code.
- [ ] Show that dependency result reporting does not consume recipe stdin or stdout contracts.
- [ ] Show that node deletion still removes host-bound Cloudify state through the existing ivps directory lifecycle.

### Phase 4 tests

- [ ] Cover two deployments claiming the same package with identical values.
- [ ] Cover rejection when one non-secret applied value differs.
- [ ] Cover an unclaimed compatible package receiving a claim without mutation.
- [ ] Cover mismatched unclaimed adoption with and without configure support.
- [ ] Cover secret comparison by reference or digest without disclosure.
- [ ] Cover teardown of one claim leaving the package installed.
- [ ] Cover last-claim teardown invoking uninstall once.
- [ ] Cover destructive override and displaced-claim reporting.
- [ ] Cover one parent with nested dependencies and one shared dependency.
- [ ] Cover failed install, failed reconfigure, failed verify, and failed uninstall.
- [ ] Cover concurrent claim additions to one subject.
- [ ] Run a real shared dependency case in the test container.
- [ ] Run focused package API, install split, registry, router, and runbook suites.
- [ ] Run `task lint` and `task test-unit` at the phase boundary.

## Phase 5: explicit secrets and ephemeral outputs

Outcome: classification is enforceable and no new state or audit artifact copies plaintext secrets.

### 5.1 Enforce declaration metadata introduced in Phase 2

- [ ] Validate the backward-compatible explicit secret marker across every declaration reader.
- [ ] Validate application-input secret metadata and mapping behavior.
- [ ] Treat undeclared legacy names with the existing name heuristic as defense in depth.
- [ ] Expose secret classification through `cloudify vars declared` without exposing content.

### 5.2 Harden storage

- [ ] Persist backend references where available.
- [ ] Persist redaction plus digest in package state for literal secrets.
- [ ] Allow literal secrets in the mode-0600 deployment input store only under the documented local trust model.
- [ ] Require the caller or deployment input to resupply a literal secret when applied state has only a digest.
- [ ] Ensure migration does not copy plaintext snapshot outputs into events.

### 5.3 Keep outputs ephemeral

- [ ] Preserve the mode-0600 `CLOUDIFY_OUTPUTS_FILE` channel within one run.
- [ ] Stop writing `output.*` into new run records and events.
- [ ] Keep old snapshot outputs readable during compatibility.
- [ ] Add an explicit command for a step to persist a later-run input deliberately.
- [ ] Persist a generated secret needed by later runs deliberately as a deployment input or secret backend reference.

### 5.4 Harden diagnostics and transport

- [ ] Remove rendered payloads from debug output.
- [ ] Log value names, source labels, and redacted status only.
- [ ] Scan Cloudify logs, event files, run files, manifests, and state for test secret literals.
- [ ] Pin SSH host keys for durable external-host state.
- [ ] Define explicit host-key rotation and stale-state acceptance.

### Phase 5 non-breakage argument

- [ ] Show that secret metadata does not alter the `envsubst` allow-list semantics.
- [ ] Show that runtime plaintext still reaches recipes that need it.
- [ ] Show that removing persisted outputs does not remove the in-run `OUT_<name>` channel.
- [ ] Trace the SSH option change against stdin payload transport, credentials, logs, local dispatch, known-host rotation, and existing node targets.

### Phase 5 tests

- [ ] Cover explicit secret and ordinary value declarations.
- [ ] Cover legacy heuristic masking.
- [ ] Cover reference, literal, and generated secret flows.
- [ ] Cover matching, missing, and mismatched literal-secret resupply for verify and teardown.
- [ ] Assert no test secret appears in any new persisted artifact or debug output.
- [ ] Cover an external host key match, mismatch, and approved rotation.
- [ ] Run focused secrets, vars, remote, runbook, registry, and logging suites.
- [ ] Run `task lint` and `task test-unit` at the phase boundary.

## Phase 6: runs, events, locking, and repair detection

Outcome: audit records are useful, same-subject writes serialize, and event-state gaps are detectable.

### 6.1 Add writer-owned event directories

- [ ] Store Cloudify events under Cloudify state.
- [ ] Do not make Cloudify and ivps write the same directory.
- [ ] Define a shared envelope version only for fields both tools genuinely share.
- [ ] Keep ivps event production outside this Cloudify implementation unless separately approved in the ivps repo.

### 6.2 Add collision-resistant IDs

- [ ] Generate run and event IDs without a new runtime dependency.
- [ ] Combine sortable UTC time with sufficient random identity or use the kernel UUID source.
- [ ] Create immutable event files without overwrite.
- [ ] Test same-second and parallel creation.

### 6.3 Integrate the existing locks with events

- [ ] Reuse the Phase 4 host mutation lock across remote execution and every top-level and dependency package result commit.
- [ ] Reuse the Phase 3 deployment manifest lock.
- [ ] Prove no path holds the host mutation lock and manifest lock together.
- [ ] Keep package mutations serialized per host.

### 6.4 Implement event-first commit

- [ ] For each result, read that package subject's current state and revision under the host mutation lock.
- [ ] Build its event and next state from the completed dispatch context and remote result.
- [ ] Atomically create that package event first.
- [ ] Atomically write that package state with revision plus one and the event ID second.
- [ ] Commit every reported dependency result sequentially under the same host mutation lock.
- [ ] Treat a multi-package dispatch as several reported subject commits, not one atomic transaction.
- [ ] Release the host mutation lock before acquiring the deployment manifest lock.
- [ ] Update the deployment manifest last from collected parent-process results.
- [ ] Detect a crash that leaves package events or claims newer than the manifest.
- [ ] Never let a state writer walk values again.

### 6.5 Detect interrupted commits

- [ ] Add `cloudify state check` in report-only mode.
- [ ] Detect an event whose resulting revision is absent from current state.
- [ ] Detect state pointing to a missing event.
- [ ] Detect duplicate or regressed subject revisions.
- [ ] Add an explicit repair flag only for deterministic state transitions.
- [ ] Never infer remote rollback from a local write failure.

### 6.6 Write run lifecycle records

- [ ] Write `running` before the first selected step.
- [ ] Update to `succeeded`, `failed`, or `interrupted` with an end time.
- [ ] Record selected phases and deployment identity.
- [ ] Store no resolved values or automatic step outputs.
- [ ] Link events by run and step IDs.

### Phase 6 non-breakage argument

- [ ] Show that events are additive and snapshots remain available.
- [ ] Show that an event write failure cannot produce a newer state revision.
- [ ] Show that one local filesystem is the declared concurrency boundary.
- [ ] Show that one host mutation lock serializes nested dependency effects without nested locks.
- [ ] Show that no claim of multi-operator safety is made.

### Phase 6 tests

- [ ] Cover parallel event IDs and immutable creation.
- [ ] Cover two concurrent writes to one subject without lost revision.
- [ ] Inject a crash after event creation and before state replacement.
- [ ] Inject a state write failure and assert the audit gap is reported.
- [ ] Inject a missing event and assert fail-closed reporting.
- [ ] Kill a run and classify it as interrupted using writer identity.
- [ ] Assert no raw output or secret enters events or runs.
- [ ] Run focused state, event, runbook, registry, and concurrency suites.
- [ ] Run `task lint` and `task test-unit` at the phase boundary.

## Phase 7: safe teardown and commit drift

Outcome: teardown releases only owned resources and refuses to pretend today's code is yesterday's application.

### 7.1 Pin application provenance

- [ ] Require a clean git commit for production application runs.
- [ ] Record the Cloudify commit in the manifest, package applied state, runs, and events.
- [ ] Add an explicit development override that marks the deployment unreproducible.
- [ ] Never label a dirty deployment replayable or exactly teardown-safe.

### 7.2 Resolve the pinned runbook

- [ ] Load the application runbook from the manifest's commit for reconfigure and teardown by default.
- [ ] Fail clearly if that commit is unavailable.
- [ ] Prevent the remote bootstrap from silently replacing the pinned recipe with branch tip.
- [ ] Prove the remote host executes the intended commit before enabling historical teardown.

### 7.3 Teardown from claims plus the pinned phase

- [ ] Select package subjects from active claims.
- [ ] Release all claims owned by the deployment, including dependency claims without uninstall actions.
- [ ] Select physical uninstalls and non-package teardown actions from the pinned runbook's teardown phase.
- [ ] Preserve explicit teardown ordering.
- [ ] Keep SSH and policy access alive until software teardown completes.
- [ ] Release an action-backed claim only after its teardown action succeeds or records an explicit retained resource.
- [ ] Release a dependency claim with no teardown action after its owning top-level teardown action succeeds, leaving the dependency installed and unclaimed.
- [ ] Refuse to remove the manifest or desired inputs while claims remain.
- [ ] Remove current manifest and desired inputs only after complete teardown.
- [ ] Keep runs and events.

### 7.4 Add explicit upgrade semantics

- [ ] Compare requested application commit with the manifest commit.
- [ ] Fail an ordinary reconfigure when the commits differ.
- [ ] Add an explicit upgrade or migration command.
- [ ] Preview added, changed, and removed stable step IDs.
- [ ] Require teardown or migration treatment for removed claimed steps.
- [ ] Update the pinned commit only after migration succeeds.

### Phase 7 non-breakage argument

- [ ] Show that direct package uninstall remains available but is claim-protected.
- [ ] Show that existing runbook teardown order remains expressible.
- [ ] Show that no branch-tip checkout is presented as pinned execution.

### Phase 7 tests

- [ ] Deploy application version 1 with two package steps.
- [ ] Remove one step in version 2 and prove ordinary teardown cannot orphan it silently.
- [ ] Prove commit mismatch blocks reconfigure and teardown.
- [ ] Prove explicit migration can release a removed claim.
- [ ] Prove one deployment teardown cannot uninstall another deployment's package.
- [ ] Prove retained claims keep the manifest present.
- [ ] Run focused teardown, claims, runbook, git-provenance, and router suites.
- [ ] Run `task lint` and `task test-unit` at the phase boundary.

## Phase 8: read surface and compatibility migration

Outcome: humans and agents can inspect current state, history, conflicts, and migration status without parsing directories.

### 8.1 Add current-state commands

- [ ] Add `cloudify deployments` by scanning current manifests.
- [ ] Add `cloudify deployment show <application>[/<flavor>] --name <name>`.
- [ ] Add host state filtering by application and deployment name.
- [ ] Show physical package state, active claims, applied version, health, and last attempt.
- [ ] Mask secrets by explicit metadata.
- [ ] Add `--json` using the versioned schema where agent composition benefits.

### 8.2 Add history commands

- [ ] Add `cloudify runs` with application and deployment filters.
- [ ] Add `cloudify run show <run-id>`.
- [ ] Keep current deployments separate from historical torn-down deployments.
- [ ] Make legacy `cloudify deployment delete` refuse v2 manifests or active claims and direct the operator to application teardown.
- [ ] Preserve old-record cleanup through the legacy delete path during compatibility.
- [ ] Show event IDs and protected log references without dumping raw logs.

### 8.3 Migrate existing data

- [ ] Add a dry-run migration inventory.
- [ ] Require explicit application and flavor mapping for each old deployment ID.
- [ ] Copy desired values to the new nested path with existing permissions.
- [ ] Convert legacy successful package observations into applied state.
- [ ] Move legacy external-host fallback state from Cloudify configuration to the Cloudify state root after fingerprint acceptance.
- [ ] Preserve removed observations as migration history rather than active claims.
- [ ] Preserve run snapshots until parity is verified.
- [ ] Never migrate `output.*` into events automatically.
- [ ] Mark ambiguous, conflicting, or incomplete records for operator review.
- [ ] Make rerunning migration idempotent.

### 8.4 Retire compatibility paths only after parity

- [ ] Compare old and new read surfaces on every migrated deployment.
- [ ] Compare old replay inputs with new desired inputs and bindings.
- [ ] Keep a documented rollback-safe release that reads old files and leaves newer state intact rather than claiming reverse transformation.
- [ ] Remove old writers before old readers.
- [ ] Remove old readers only in a later release with explicit consent.
- [ ] Archive old snapshots only after backup and parity acceptance.

### Phase 8 tests

- [ ] Cover empty, active, degraded, interrupted, and torn-down deployments.
- [ ] Cover one host shared by several deployments.
- [ ] Cover old and new stores present together.
- [ ] Cover idempotent migration and ambiguous migration refusal.
- [ ] Cover JSON and concise human output.
- [ ] Run focused migration and read-surface suites.
- [ ] Run `task lint` and `task test-unit` at the phase boundary.

## Phase 9: documentation, skills, and acceptance

Outcome: the shipped language and operator workflows match the implemented behavior.

### 9.1 Update project documentation

- [ ] Update README application, deployment, value, state, run, event, and teardown sections.
- [ ] Update `runbooks/README.md` with canonical tree shape, phase rules, mappings, binding persistence, and commit drift.
- [ ] Update package author documentation with package-instance and secret declaration rules.
- [ ] Remove statements that registry state is never a source without the reconfigure exception.
- [ ] Propose the required `AGENTS.md` or `CLAUDE.md` architecture-map changes and obtain Rachid's explicit consent before editing either harness file.
- [ ] Remove obsolete single-ID deployment examples after compatibility ends.
- [ ] Update ROADMAP items made obsolete or deliberately deferred.

### 9.2 Update skills

- [ ] Update the `cloudify` skill with the final user-facing commands and examples.
- [ ] Update `cloudify-dev` with the dispatch-context, state, claim, locking, and event invariants.
- [ ] Update `cloudify-pkg-dev` only if recipe declarations or package-instance support changed.
- [ ] Keep the CRITICAL GATE and shadow warnings prominent.

### 9.3 Disposable E2E

- [ ] Push the final branch before remote testing.
- [ ] Use disposable application and deployment names.
- [ ] Run one two-host application with a shared secret input.
- [ ] Confirm first install works without prior package state.
- [ ] Confirm reconfigure uses desired input over last applied value.
- [ ] Confirm failed reconfigure preserves applied state and records the attempt.
- [ ] Add a second deployment claiming one shared package.
- [ ] Confirm conflicting configuration fails before mutation.
- [ ] Confirm first teardown leaves the shared package installed.
- [ ] Confirm last teardown removes it.
- [ ] Interrupt one run and confirm status plus state-check output.
- [ ] Scan all new artifacts and logs for the test secret.
- [ ] Reach the explicit human gate and record the result.
- [ ] Teardown all disposable resources and prove policy restoration.

### 9.4 Final gates

- [ ] Run `task lint`.
- [ ] Run the full Cloudify unit suite once on final HEAD.
- [ ] Run only named integration suites affected by the final diff.
- [ ] Run the disposable E2E once on final HEAD.
- [ ] Obtain an independent read-only review with zero blockers.
- [ ] Update `HISTORY.md`, `ADR.md` through a new ADR if decisions changed, and `LOGS.md`.
- [ ] Archive this plan and repoint `PLAN.md` only after every accepted task is complete.
- [ ] End with `git status --short` clean.

## Deferred work

- [ ] Design multi-operator writes only after choosing a coordination service.
- [ ] Design secret-aware backup before registry replication.
- [ ] Give ivps immutable node and instance IDs in a separate ivps ADR and migration.
- [ ] Normalize ivps provider, origin, spec, address, role, gateway, and engine fields separately.
- [ ] Consider command replay only after audit events have complete production coverage.
- [ ] Consider log folding only after state repair has a proved need.
- [ ] Consider automatic host rename migration only after stable inventory IDs exist.

Deferred tasks are not blockers for this plan and must not be pulled into its implementation without a new decision and consent.
