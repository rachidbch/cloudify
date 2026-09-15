# Phase 4 design: physical package state, events, claims, and safe results

Status: draft for the Phase 4 design gate (R3).

This document authorizes no code.

It needs the independent SPEC review, Technical review, and Rachid's consent required by `plans/state-model-v2-recovery.md` before implementation starts.

## Outcome

Phase 4 replaces the per-deployment registry observation with one schema-valid state record for each physical package instance.

Every state revision is backed by one immutable event.

One operator-side worker holds one durable-host lock from before remote mutation through every top-level and dependency result commit.

Claims prevent one deployment from changing or removing a package instance still used by another deployment.

The remote result channel reports package work without changing recipe stdin or exposing framework records as recipe stdout.

## Authority and scope

This design derives from:

- `REDESIGN.md`, especially Physical package state and claims, Application lifecycle and phases, Runs and events, Write protocol, and Migration and removal.
- ADR-022, ADR-023, and ADR-024.
- `schemas/v1/package-state.schema.json`.
- `schemas/v1/event.schema.json`.
- `schemas/v1/run.schema.json`.
- The flat dispatch-context contract in `lib/context.sh`.
- The Phase 4 requirements in `plans/state-model-v2-recovery.md`.

Phase 4 includes:

- immutable package events;
- revisioned physical package state;
- inventory-host and package-instance identity;
- one host mutation lock;
- the framed remote result protocol;
- phase-specific state resolution;
- compatible claims and protected teardown;
- one temporary old-registry migration command;
- deletion of the runtime registry writer.

Phase 4 does not include:

- the roadmapped JSON dispatch context;
- run-record persistence or interrupted-run classification;
- external-host durable state before SSH host-key acceptance;
- pinned historical execution;
- event replay;
- multi-operator coordination;
- automatic removal of old migration sources.

## Reconciliation against current HEAD

The current tree has no accepted Phase 4 implementation.

`lib/state.sh` writes deployment manifests only.

Its event directory helper is present, but there is no event renderer, validator, or writer.

There is no physical package-state path or writer.

The only lock is the deployment manifest lock.

`lib/remote.sh` merges command output into the normal SSH stream and has no nonce-bound frame or private result body.

`lib/package-api.sh` knows dependency depth but reports no per-package result and no dependency parent.

`lib/registry.sh` still writes one observation per deployment, target, and package after a successful dispatch.

`tests/unit/golden-fixtures.bats` still combines the eight byte-exact payload cases with nine registry-writer cases.

The flat context already carries each resolved name's source label, raw source form, reference, secret flag, and literal-secret digest.

It does not carry the classification origin required by the package-state and event schemas or the resolved instance identity for each package in the graph.

Phase 4 therefore adds two field shapes to the existing flat context without converting the context to JSON:

```text
value.<NAME>.declaration: explicit|heuristic|none
package.<PACKAGE>.instance: <validated-instance>
```

The declaration field is derived during the existing single resolution, beside `value.<NAME>.secret`, and no later writer reopens a declaration file or value store.

The package-instance field is derived after that resolution from the package's optional instance variable and defaults to `default`.

A valid secret reference or a package `secret <NAME>` marker yields `explicit`.

Otherwise a matching secret-name heuristic yields `heuristic`.

Every other name yields `none`.

This is a fragile context-format change and needs Rachid's go before implementation.

The manifest and run schemas already accept a real JSON null commit only with `development_override: true`, and their valid and invalid fixtures already pin that rule.

The package-state schema is only a preliminary contract.

It still permits null event IDs, and its migrated fixture still uses them.

The event schema cannot yet identify a registry migration without pretending it was an application phase.

Both schemas need the changes specified below before the first package-state writer lands.

## Files and ownership

Keep one owner per concern.

- `lib/state.sh` owns the Cloudify state root, the shared JSON-schema validator, collision-resistant IDs, immutable event creation, writer identity, and deployment manifest locking.
- `lib/package-state.sh` is new and owns durable host identity, host-state paths, package-state rendering, state transitions, claims, and registry migration into package state.
- `lib/results.sh` is new and owns private result files, the result-object contract, frame rendering, frame parsing, and expected-graph reconciliation.
- `lib/package-api.sh` emits one result object around each install attempt made through `pkg_depends`.
- `lib/packages.sh` emits the same result shape around configure, verify, and uninstall attempts.
- `lib/remote.sh` transports the execution plan and framed result while preserving the existing payload and recipe streams.
- `lib/runbooks.sh` supplies application identity, clean commit, run ID, stable step ID, selected phase, and manifest updates.
- `lib/registry.sh` retains only the old-format reader needed by `cloudify state migrate-registry` until Phase 8 deletes it.
- `cloudify` owns dispatch-worker lifecycle, unconditional context cleanup, and the final manifest result.

No package-state writer may land in a commit that lacks the immutable event writer it calls.

No second JSON encoder, schema validator, context walker, dependency parser, or lock implementation is added.

## Artifact paths and identity

### Inventory hosts

Phase 4 writes durable state only for an ivps inventory node or instance.

For a node target:

```text
host_key = ivps:<node>
host_state_root = $(ivps node path <node>)
```

For an instance target:

```text
host_key = ivps:<node>:<instance>
host_state_root = $(ivps node path <node>)/<instance>
```

The operator-facing `host` remains the resolved target address recorded by the binding or direct dispatch.

The physical package state path is:

```text
<host_state_root>/cloudify/packages/<package>/<package-instance>/state.json
```

The one host mutation lock is:

```text
<host_state_root>/cloudify/.host-mutation.lock
```

The lock is keyed by the durable host root only.

Package and package instance never enter the lock key.

An external SSH alias has no durable key in Phase 4.

A state-bearing package command targeting one fails before remote execution until Phase 5 accepts its SSH host key.

### Package instances

Every package instance defaults to `default`.

A package opts into non-default instances with `pkg/<package>/.package-instance`.

That file contains exactly one declared variable name, such as `CLOUDIFY_POSTGRES_CLUSTER`.

The same name must appear in the package's `.remote-vars` declaration and is resolved through the ordinary dispatch context.

An absent or empty instance value means `default`.

A non-empty value is validated with the frozen package-instance component rule and becomes the instance for that package in the expected graph, result, event, state path, and claim.

A package without `.package-instance` rejects any attempted non-default identity.

The recipe receives the same already-forwarded variable and needs no new function signature.

After resolution, the context records one sorted `package.<package>.instance` field for every precomputed top-level package and dependency.

The result writer and operator-side reconciler read that same identity instead of recomputing it from mutable environment state.

These are per-package identity fields, not per-package value views, so ADR-024's one global value namespace remains unchanged.

The framework-owned result path, execution plan, and frame nonce are not package-instance inputs.

## Commit provenance

A newly written successful `applied` object must carry the 40-hex commit of the clean Cloudify checkout whose recipe ran.

This applies to application package mutations and new direct package mutations.

An application dispatch uses the same proved clean commit as its manifest.

A direct package dispatch proves the clean checkout commit before mutation even though its event has no application tuple.

A dirty or unidentified checkout fails before a state-bearing package mutation.

The only operation allowed to create `applied.application_commit: null` is a proved old-registry migration.

Its linked event carries the migration origin described below.

Direct-command events keep `application`, `flavor`, `deployment`, and event `application_commit` null because they have no application context.

That event-level null does not permit a new direct command to write a null `applied.application_commit`.

The existing nullable manifest and run fields stay unchanged.

Their `development_override` rule does not authorize an unreproducible Phase 4 package mutation.

This clarification must be aligned in `REDESIGN.md`, the schema descriptions, and the recovery plan when Rachid accepts this design.

## Schema changes before writers

The state and event substrate step (4.1) changes schemas and fixtures before adding a package-state writer.

### Package state

Tighten `schemas/v1/package-state.schema.json` so:

- `applied.event_id` is a non-null event ID whenever `applied` is an object;
- `last_attempt.event_id` is a non-null event ID whenever `last_attempt` is an object;
- `health.event_id` is always a non-null event ID;
- every claim has a non-null `event_id`;
- a missing state has conceptual revision 0, but the first persisted state has revision 1;
- `applied.application_commit` remains nullable only because migration may not invent provenance.

A new or migrated state with no verification uses `health.status: unknown`, `checked_at: null`, and the event ID that created the state.

A nullable `last_attempt` remains valid because migration is not a package attempt.

Update every package-state valid fixture to use non-null event IDs.

Add invalid fixtures for null event IDs in applied, last attempt, health, and claims.

The migrated-observation fixture gets its migration event ID and keeps `application_commit: null`.

### Events

Extend `schemas/v1/event.schema.json` with one explicit registry-migration shape instead of encoding migration as install.

A normal package event has `origin: null`.

A migration event has:

```json
{
  "phase": null,
  "command_kind": "migrate-registry",
  "origin": {
    "kind": "registry",
    "path": "/absolute/source/config.yaml",
    "sha256": "<64 lowercase hex>"
  }
}
```

The event schema requires `origin`, permits `phase: null` only for `migrate-registry`, and requires a non-null registry origin for that command kind.

The event value-source enum gains `migration` for facts read from the old record.

Migration events use a package subject, `run_id: null`, `step_id: null`, no deployment tuple, a fixed bounded summary, and state revisions 0 to 1.

Normal package events retain the four application phases and existing command kinds.

Add valid and invalid migration-event fixtures, including a missing origin, a non-absolute source path, a bad source digest, and migration with a non-null application phase.

Keep `bash schemas/v1/validate.sh` green before any writer code.

## One context projection

Projection reads the existing context once and never reads a value source again.

ADR-024 makes resolved values dispatch-global.

Every reported package result therefore projects the same set of resolved context names.

This conservative rule may reject sharing when an unrelated dispatch value differs, but it never omits a value that configured a dependency through the configuration-package pattern.

A later per-package usage contract would need its own decision and is not smuggled into Phase 4.

For each `value.<NAME>` block, decode the `t:` or `b:` transport in `raw` once.

Produce these package-state fields:

- Non-secret literal: `source_form` is the decoded raw form, `reference: null`, `digest: null`, `redacted: false`.
- Secret reference: `source_form` and `reference` are the reference text, `digest: null`, `redacted: false`.
- Literal secret: `source_form: null`, `reference: null`, the existing sha256 digest, and `redacted: true`.
- Every value carries the context's `secret` and `declaration` fields.

The same state projection populates `last_attempt.requested` for every result.

It populates `applied.values` only after a successful install or reconfigure.

It populates a new claim's `values` and the values of a successfully reconfigured sole claim.

Produce these event fields:

- map context source `environment` to schema source `caller`;
- preserve `deployment`, `application`, `package`, `global`, and `recipe`;
- use `applied` when phase-specific resolution seeded the value from successful state;
- carry `secret` and `declaration`;
- carry a secret reference or literal-secret digest, never both;
- carry neither for a non-secret;
- never carry `source_form`, `raw`, or resolved runtime plaintext.

The projection fails closed on a missing field, malformed raw transport, inconsistent secret metadata, unknown source label, or secret literal without a digest.

The package-state and event projections are built together from one parsed context so they cannot classify the same name differently.

## IDs, writer identity, and validation

Run and event IDs use the schema's sortable form:

```text
YYYYMMDDTHHMMSSZ-<8 lowercase random hex>
```

The suffix comes from four bytes read from `/dev/urandom` with existing base-system tools.

Creation retries with a new suffix on collision.

It never overwrites an existing ID.

An application execution generates one run ID before its first selected step and exports it to every package dispatch.

Phase 4 uses that ID in events and claims but does not create a run record.

Phase 6 adds the run writer around the already-stable ID.

Direct commands and registry migration use `run_id: null`.

Writer identity is read once per operator-side worker from hostname, `/proc/sys/kernel/random/boot_id`, `$$`, and `/proc/$$/stat` field 22.

Extend the existing jq-backed validator into one shared `cloudify_state_validate_file <schema> <file>` implementation.

Manifest validation delegates to it rather than keeping a second checker.

Every writer checks jq, its schema, and its destination prerequisites before creating a durable directory or lock.

## Immutable event and state write protocol

Events live at:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/cloudify/events/<year-month>/<event-id>.json
```

The event writer:

1. Renders one complete JSON event into a mode-0600 temporary file in the destination directory.
2. Validates it against `event.schema.json`.
3. Creates the final name atomically without overwrite.
4. Retries with a new event ID only when that final name already exists.
5. Never edits or replaces a committed event.

The no-overwrite create uses a same-filesystem primitive whose existing destination fails, not `mv -f` or a check-then-move race.

A package-state transition runs under the host lock:

1. Read and validate the current state, or use conceptual revision 0 when no file exists.
2. Derive the complete next state from the current state, the validated result, and the one context projection.
3. Set `next_revision = current_revision + 1`.
4. Render the event with `previous_revision = current_revision` and `resulting_revision = next_revision`.
5. Put that event ID on every state object created or changed by this transition.
6. Render and validate the complete next state into a mode-0600 temporary file in the state directory.
7. Atomically create the immutable event.
8. Atomically replace `state.json` with the validated next state.
9. Re-read the committed revision and event ID before reporting success.

No state write occurs when event creation fails.

If event creation succeeds and state replacement fails, the worker reports the event path and absent resulting revision as a repairable gap and fails the dispatch.

If state points to a missing event, the reader reports corruption and refuses another mutation.

Phase 4 provides the subject-level checks needed by the writer and focused tests.

Phase 6 exposes the full fleet report and explicit repair command as `cloudify state check`.

A local state-write failure never implies that the remote mutation rolled back.

## State transitions

Each attempted package result produces one event and one state revision.

Unchanged nested objects keep their earlier event IDs.

Changed nested objects receive the new event ID.

### Install and reconfigure

A successful install or reconfigure:

- writes `last_attempt.outcome: succeeded`;
- replaces `applied` with the proved commit, `package_version: null`, projected values, time, and event ID;
- writes health `ok` when its verification hook succeeded;
- writes health `unknown` when no verification hook ran;
- adds or updates only the compatible claim authorized for that operation.

A failed install or reconfigure:

- preserves `applied` exactly;
- preserves existing claims exactly;
- writes `last_attempt.outcome: failed`;
- writes health `degraded` with the attempt time and event ID;
- adds no first-install claim.

### Verify

Verify never changes `applied` or claim values.

It writes `last_attempt` and health `ok` or `degraded` from the result.

A verify-only value override affects that attempt's event and requested projection but not applied state.

### Teardown

Removing a claim while another claim remains is a local state transition with no uninstall recipe.

Removing an unclaimed dependency not named by the pinned teardown leaves `applied` intact.

For the last claim on a package named by teardown, the claim remains in current state while the uninstall recipe runs.

On successful uninstall, one transition removes the claim, sets `applied: null`, records the successful teardown attempt, and sets health to `unknown`.

On failed uninstall, the transition preserves both the claim and `applied`, records the failed attempt, and sets health to `degraded`.

This avoids turning a failed physical teardown into an ownerless installed package.

A direct uninstall has no claim to release and is blocked while any deployment claim exists unless the later destructive-override contract is satisfied.

## Expected dependency graph

Before taking the host lock, Cloudify expands the same static top-level and `pkg_depends` graph used to build the context.

One graph row contains:

- immediate parent package, or null for a top-level package;
- package name;
- resolved package instance;
- selected phase;
- operation kind;
- run and stable step identity when present.

The graph is written to a private mode-0600 file.

After taking the host lock, the worker reads every potentially touched subject and builds an execution plan.

The plan says whether a reported package may mutate, verify only, add a compatible claim without mutation, release a claim without uninstall, uninstall, or fail before remote execution.

Both local and remote package wrappers consult that plan before recipe code.

A conditional dependency that is in the static graph but is not called at runtime produces no result and no state transition.

Every requested top-level package must report exactly one result.

Every dependency actually attempted must report one result with its immediate parent.

A reported package, parent edge, instance, phase, or operation absent from the precomputed graph rejects the whole result body before any result is committed.

This catches dynamic or forged dependency work without inventing values after execution.

Repeated subjects may produce ordered results from different graph edges.

They commit in result order under the same host lock, each with its own event and revision.

## Private result contract

The transport body is JSON, but it is not a persisted v2 artifact and gets no file under `schemas/v1/`.

`lib/results.sh` owns one jq validator used by both local and remote paths.

The compact body is:

```json
{
  "protocol_version": 1,
  "child_exit_status": 0,
  "results": [
    {
      "parent": null,
      "package": "nginx",
      "package_instance": "default",
      "phase": "install",
      "command_kind": "install",
      "outcome": "succeeded",
      "exit_status": 0,
      "verification": "ok"
    }
  ]
}
```

Exact rules:

- `parent` is null for a top-level package and the immediate package name for a dependency.
- `package` and `package_instance` identify the state subject.
- `phase` is one of the four application phases.
- `command_kind` is `install`, `configure`, `verify`, or `uninstall`.
- `outcome` is `succeeded` or `failed`.
- `exit_status` is an integer from 0 through 255 and agrees with outcome.
- `verification` is `ok`, `failed`, or `not-run`.
- Normal Phase 4 writes set package-state `package_version` to null because no recipe-version reporter exists.
- No value, environment snapshot, stdout, stderr, payload, path, nonce, claim, or free-form summary is allowed.
- Every object has exactly these fields.
- The body is at most 1 MiB before framing.

The package wrapper runs recipe code in the same subshell boundary used today, captures its status after it exits, appends one compact JSON object to the private result file, and returns the original status.

A recipe `exit`, dependency failure, or verification failure therefore cannot bypass its framework result.

The result append itself writes no stdout or stderr on success.

For a local dispatch, the operator-side worker creates the mode-0600 result file, the local child appends JSON lines, and the worker compacts and validates them after the child exits.

For a remote dispatch, the outer remote shell creates the mode-0600 result file and gives only its path and execution plan to the child Cloudify process.

After that child exits, the outer shell compacts the file with the captured child status, frames it on stdout, removes the private file, and exits with the child's status unless framing itself failed.

The recipe remains trusted code and can inspect inherited process state as root.

This channel prevents accidental output collisions and ordinary framework ambiguity.

It is not a security boundary against a hostile remote root.

## Framed remote stdout protocol

The local operator-side parent generates 16 random bytes per dispatch and renders them as 32 lowercase hex characters.

It bakes that nonce as a single-quoted local variable into the outer remote shell.

The variable is not exported, is not passed in argv, and is not present in the child Cloudify process or recipe environment.

The outer shell emits the frame only after the child Cloudify process exits.

The frame bytes are exactly:

```text
\n__CLOUDIFY_RESULTS_V1_START__ <32-hex-nonce>\n
length:<canonical-decimal-encoded-body-length>\n
sha256:<64-lowercase-hex-digest-of-encoded-body>\n
<base64-body-with-no-line-wrap>\n
__CLOUDIFY_RESULTS_V1_END__ <same-32-hex-nonce>\n
```

The leading newline is part of the frame, so a recipe's unterminated final line is not changed when the whole frame is removed.

The encoded body is base64 without wrapping.

`length` counts encoded body bytes, not decoded JSON bytes.

The digest covers those exact encoded bytes.

The parser knows the expected nonce before it reads SSH stdout.

It rejects:

- no exact start marker;
- more than one exact start marker;
- no exact end marker;
- more than one exact end marker;
- a different end nonce;
- an end before its start;
- a non-canonical or out-of-range length;
- a truncated or overlong body;
- a malformed digest;
- a digest mismatch;
- invalid base64;
- invalid JSON;
- a body above the limit;
- an invalid result object;
- an unexpected graph member;
- a missing or duplicate requested top-level result.

A marker printed by a recipe without the random nonce is ordinary output.

Every byte before and after the one accepted frame is passed to the existing host-prefix and protected-log path in its original order.

The parser removes only the exact frame span and does not line-normalize, decode, trim, or reinterpret non-frame output.

Recipe stdin remains exactly as today: remote package commands receive `</dev/null`, and the SSH payload remains on stdin to `bash -s`.

Recipe stdout and stderr still enter the ordinary combined output stream.

A valid frame is metadata at the tail of that stream, not recipe output.

A successful SSH child with no valid frame is a failed dispatch because remote mutation may have happened without attributable results.

The manifest becomes degraded, no package result is guessed, and no rollback is inferred.

A valid frame is fully parsed and reconciled before the first package event or state commit.

Valid results are then committed in order even when the child exit status is non-zero, so successful dependencies are not discarded because a later package failed.

Any failed result, child failure, frame failure, or commit failure makes the dispatch and manifest degraded.

## One host lock

A local dispatch worker, which is the operator-side parent of the local or remote package child, owns the host mutation lock.

It acquires the lock before reading claim compatibility or starting remote execution.

It holds the same lock through frame validation, graph reconciliation, every package event creation, and every package-state replacement.

It releases the lock only after all committable results finish or a failure is recorded.

No package or dependency acquires another lock.

The lock wait defaults to the existing bounded state timeout and remains configurable through `CLOUDIFY_LOCK_TIMEOUT`.

After acquisition, the holder writes bounded non-secret metadata into the locked file:

- writer host;
- boot ID;
- PID and process start ticks;
- acquired time;
- durable host key;
- run ID or `direct`.

A timeout prints that metadata and the waited duration.

The metadata is diagnostic only and does not decide lock ownership.

`flock` decides ownership.

The runbook parent updates the deployment manifest only after every host worker has exited and therefore released its host lock.

Manifest updates continue under the separate per-deployment lock.

A test-only assertion fails if manifest lock acquisition occurs while the process still owns a host-lock descriptor.

Different durable hosts use different lock files and remain parallel.

Two aliases resolving to the same durable inventory host serialize on one file.

## Claims and phase decisions

Claims exist only for an application package step with a complete deployment tuple and stable step ID.

A dependency claim uses the same deployment tuple and stable step ID as the top-level step that pulled it.

Direct package commands never create claims.

Compatibility compares:

- package and package instance;
- last successful recipe or package version;
- every dispatch-global projected value;
- non-secrets by source form;
- secret references by reference;
- literal secrets by digest.

Conflict diagnostics name package, instance, and conflicting deployment tuples.

They print value names and comparison class only.

They never print either value, reference locator, or digest.

Install decisions under the host lock are:

- Missing state: run install and add the claim only after success.
- Same active claim and no explicit difference: skip install and run verify.
- Compatible state without this claim: add the claim without recipe mutation, then verify when the phase requires it.
- Explicit input differing from applied or any active claim: fail before recipe code and direct the operator to reconfigure or upgrade.
- Unclaimed incompatible state: require `--adopt`, require configure support, run configure, and add the claim only after success.

Reconfigure requires an existing successful applied object and this deployment's active claim.

Its resolution order is caller, deployment, applied, application, package, global, recipe.

It fails before mutation when another active claim would become incompatible.

A successful reconfigure replaces applied values and this claim's values in one event-backed revision.

Verify and teardown seed from last successful applied source forms.

A failed `last_attempt` is never a source.

A redacted literal secret must be resupplied by caller or desired inputs and must match its stored digest before remote execution.

Changed defaults do not affect an existing claim, verify, or teardown.

Claim checks and execution-plan decisions happen under the host lock before recipe code.

## Registry writer removal

The runtime registry writer ends in Phase 4 when the first package-state writer becomes active.

In the same slice:

- delete `_cloudify_registry_record_bg` and every runtime record-build, apply, put, delete, and listing path not needed by migration;
- remove registry bookkeeping arrays and success-path calls from `cloudify`;
- make the wait-loop context removal unconditional on both success and failure;
- keep the existing process EXIT cleanup as the backstop;
- preserve the success, failure, interruption, direct-command, and DEBUG context-leak proofs;
- keep only a narrow old-record reader called by `cloudify state migrate-registry`;
- prove no runtime command calls that reader.

Split `tests/unit/golden-fixtures.bats` at the same time.

The eight `tests/fixtures/golden/payload/*` files and their byte-exact `cmp` tests stay unchanged.

Move the old registry record bytes out of `tests/fixtures/golden/registry/` into migration-reader fixtures without recapturing them.

Delete the registry-writer half of the golden suite.

The migration step (4.7) owns those moved input fixtures and the narrow old-format reader tests.

## Registry migration

The temporary command is `cloudify state migrate-registry`.

It is the sole old-registry reader.

Dry-run is the default.

`--apply` is required to write.

The command accepts an explicit old deployment ID that identifies the registry tree to inspect.

It accepts no application mapping because the migrated physical observation is unclaimed and no v2 artifact would use that tuple.

The separate desired-input migration owns explicit application, flavor, and deployment mapping.

For each inventory-node or instance record with `status: installed` or `configured`, it may prove only:

- host and durable inventory host key from the bucket;
- package name;
- package instance `default`;
- recorded package version when present;
- successful observation time when present;
- old source-form `var.*` values;
- old source path and its sha256 digest.

It never infers application commit, run ID, step ID, health, target binding, or historical event sequence.

It ignores persisted `output.*` fields.

A removed record is reported but does not create applied state.

An external-host fallback record is reported but not migrated until Phase 5 can prove its host key.

An applied migration writes:

1. one validated immutable `migrate-registry` event from revision 0 to 1;
2. one validated state at revision 1;
3. `applied.application_commit: null` linked to that event;
4. `last_attempt: null`;
5. health `unknown`, `checked_at: null`, linked to that event;
6. no claims.

Migration uses the same event-first state writer under the same host lock.

It never invokes a recipe.

It leaves the old source file in place.

Idempotency is keyed by the origin path and source digest carried in the migration event.

An identical already-migrated observation reports no change.

Existing different v2 state or a changed old source fails with both paths and no values.

Phase 8 owns verified source deletion and removal of this command, reader, and old-format input fixtures after inventory reaches zero old artifacts.

The event schema, its migration event fixture, and already-written immutable migration events remain part of schema version 1.

## Failure boundaries

The following all fail closed before remote mutation:

- no durable inventory host identity;
- no clean checkout commit for a new normal applied write;
- invalid package or instance component;
- missing schema or validator;
- malformed context or projection;
- unresolved required redacted secret;
- claim conflict;
- host-lock timeout;
- invalid execution plan.

The following may occur after remote mutation and therefore mark the deployment degraded without claiming rollback:

- child process failure;
- missing or invalid result frame;
- unexpected reported package;
- event-create failure;
- state-replace failure;
- a later result commit failing after earlier results committed.

Detailed recipe output remains only in the existing protected log.

Events contain fixed bounded summaries generated by the framework.

## Tests frozen before implementation

Write one red test at a time in this order.

### Schema and projection

- Every valid state object has non-null event IDs.
- Null event IDs in applied, attempt, health, or claim fail schema validation.
- Migration event origin is required and bounded.
- Normal events reject a migration origin.
- Plain, escaped-at, multiline, reference-secret, explicit literal-secret, heuristic literal-secret, empty, spaces, quotes, colons, and shell metacharacters project correctly.
- State and event projections come from a context after every value source is made unavailable.
- No literal fixture secret appears in state, event, result body, stdout, debug output, or log.

### Event and state writes

- Invalid components and missing jq/schema create no directory or lock.
- A state file is real JSON and validates before replacement.
- An invalid next state leaves the prior bytes unchanged.
- Event creation failure leaves state unchanged.
- State replacement failure leaves one detectable event-to-state gap.
- State pointing to a missing event is reported and blocks mutation.
- Two successive results produce revisions 1 and 2 with matching event links.
- An existing event ID is never overwritten and causes ID retry.
- A failed attempt preserves applied bytes and claims.

### Package instance and host identity

- No marker defaults to `default`.
- A declared instance variable selects a validated non-default instance.
- A non-default instance without recipe support fails before mutation.
- Node and instance targets produce distinct durable keys and state roots.
- Two aliases of one inventory host produce one host lock.
- An external target fails before remote execution.

### Locking

- Same-host workers serialize remote execution and all result commits.
- Different-host workers can overlap.
- Dependencies acquire no nested lock.
- Timeout is bounded and prints the current holder metadata.
- The host lock is released before the manifest lock is acquired.
- A partial multi-package commit keeps earlier event/state pairs valid.

### Results and framing

- Local package results stay in the private file and never enter stdout.
- A top-level and nested dependency report parent, package, instance, phase, operation, status, verification, and no values.
- Recipe success, return failure, `exit`, dependency failure, and verify failure each emit one accurate result.
- The random nonce is absent from child and recipe environments.
- Recipe stdin remains unchanged.
- Non-frame stdout bytes, including an unterminated final line and a fake marker, round-trip byte exact.
- Missing, duplicate, truncated, malformed, overlong, bad-length, bad-digest, bad-base64, bad-JSON, and wrong-nonce frames fail.
- An unexpected package, parent, instance, phase, or operation prevents every commit from that body.
- A missing or duplicate top-level result fails.
- A successful dependency result commits even when a later top-level result fails.
- The eight payload goldens remain byte-identical.

### Claims, phases, and migration

- Compatible claims share one state record.
- Conflicting explicit input fails before recipe code and prints no secret material.
- Existing-claim install skips install and verifies.
- Failed first install adds no claim.
- Failed reconfigure preserves applied and claim values.
- Shared teardown releases one claim without uninstall.
- Failed last-claim uninstall preserves the claim and applied state.
- Successful last-claim uninstall clears applied and the claim.
- Verify and teardown seed only from successful applied values.
- A failed attempt never seeds another phase.
- Migration dry-run writes nothing.
- Migration apply writes event first, then revision 1 state with null applied commit and no claims.
- Repeating identical migration is a no-op.
- Conflicting migration fails without exposing values.
- External and removed records are reported but not migrated.
- Runtime searches find no old-registry reader caller outside the migration command.

No implementation test may weaken the byte-exact payload goldens or a fragile-surface pin.

## Implementation sequence

### 4.1 State and event substrate

1. Add red schema fixtures and projection tests.
2. Add the flat context declaration-origin field under the fragile-surface gate.
3. Generalize the one jq schema validator.
4. Add ID and writer-identity helpers.
5. Add immutable event rendering and creation.
6. Add physical package-state rendering and event-first replacement.
7. Add subject-level gap detection.

No package-state writer lands before step 5 is complete and green.

### 4.2 Package instance and host identity

1. Add the `.package-instance` contract and tests.
2. Resolve instance identity from the already-built context.
3. Add inventory host key, host root, state path, and host-lock path helpers.
4. Reject external durable state.

### 4.3 Host lock and result channel

1. Freeze the lock, private-result, frame, passthrough, and graph-reconciliation tests.
2. Add the operator-side dispatch worker and bounded host lock.
3. Add framework result emission around package attempts.
4. Add remote frame emission and local frame parsing.
5. Validate the whole result body before ordered commits.
6. Delete the runtime registry writer and split its goldens.
7. Prove unconditional context cleanup and byte-identical payloads.

The framed-result format is a fragile transport contract and needs Rachid's go before this slice.

### 4.4 Phase-specific resolution

1. Add applied source forms below explicit reconfigure sources.
2. Seed verify and teardown from applied only.
3. Require matching resupply for redacted literals.
4. Keep install defaults from reinterpreting an existing claim.

### 4.5 Claims and adoption

1. Add pre-mutation compatibility checks under the host lock.
2. Add claim-only and verify-only execution-plan decisions.
3. Add claims only after compatible success or adoption.
4. Add guarded configure-based adoption.

### 4.6 Teardown and failure state

1. Add shared claim release without uninstall.
2. Add last-claim uninstall ordering.
3. Preserve applied and ownership on failure.
4. Record degraded or unknown health through event-backed transitions.

### 4.7 Migration and phase gate

1. Consume the old registry bytes moved into migration fixtures in step 4.3.
2. Add the narrow old-record reader and dry-run command.
3. Add idempotent event-first apply for inventory hosts.
4. Run focused suites, one real shared-dependency case, lint, full unit, and the Phase 4 E2E scenarios.
5. Obtain final SPEC and Technical implementation reviews before the phase commit.

## Gate conditions

The design gate (R3) is complete only after:

- this document has no unresolved must-fix review finding;
- SPEC review returns `PASS` with file and line evidence;
- Technical review returns `PASS` with file and line evidence;
- Rachid explicitly consents to the context-format and framed-result contract changes;
- accepted clarifications are aligned in `REDESIGN.md`, the recovery plan, schemas, and ADR trail before code.

This turn performs none of those acceptance steps.
