# Phase 4 design: physical package state, events, claims, and safe results

Status: draft, revision 2, after the one-pass SPEC and Technical reviews.

Revision 2 resolves the six SPEC and six Technical must-fix findings recorded on 2026-09-15.

This document authorizes no code.

It needs Rachid's consent, and the supersessions listed in Gate conditions, before implementation starts.

## Outcome

Phase 4 replaces the per-deployment registry observation with one schema-valid state record for each physical package instance.

Every state revision is backed by one immutable event.

One operator-side worker holds one durable-host lock from before remote mutation through result-line capture and every top-level and dependency result commit.

Claims prevent one deployment from changing or removing a package instance still used by another deployment.

Remote results travel as one marked line the child itself emits on the existing streamed log, so recipe output, the live streaming chain, and the SSH payload bytes never change.

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
- the private result-file channel;
- phase-specific state resolution;
- compatible claims and protected teardown;
- the claim-release override for direct uninstalls;
- the commit-drift gate for reconfigure and teardown;
- one temporary old-registry migration command;
- deletion of the runtime registry writer.

Phase 4 does not include:

- the roadmapped JSON dispatch context;
- run-record persistence or interrupted-run classification;
- external-host durable state before SSH host-key acceptance;
- pinned historical execution beyond the drift gate;
- event replay;
- multi-operator coordination;
- automatic removal of old migration sources.

## Reconciliation against current HEAD

The current tree has no accepted Phase 4 implementation.

`lib/state.sh` writes deployment manifests only.

Its event directory helper is present, but there is no event renderer, validator, or writer.

There is no physical package-state path or writer.

The only lock is the deployment manifest lock.

`lib/remote.sh` appends the package command to the payload and merges all remote output into the ordinary SSH stream.

`lib/packages.sh` and `lib/package-api.sh` know dependency depth but report no per-package result and no dependency parent.

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

The event schema cannot yet identify a registry migration without pretending it was an application phase, and it forces a non-null commit whenever an application tuple is present, which a development-override run contradicts.

Both schemas need the changes specified below before the first package-state writer lands.

## Files and ownership

Keep one owner per concern.

- `lib/state.sh` owns the Cloudify state root, the shared JSON-schema validator, collision-resistant IDs, immutable event creation, writer identity, and deployment manifest locking.
- `lib/package-state.sh` is new and owns durable host identity, host-state paths, package-state rendering, state transitions, claims, and registry migration into package state.
- `lib/results.sh` is new and owns the result-body contract, the remote child's private result file and marked-line emission, the local capture tap and result reading, validation, and expected-graph reconciliation.
- `lib/package-api.sh` emits one result object around each install attempt made through `pkg_depends`.
- `lib/packages.sh` emits the same result shape around configure, verify, and uninstall attempts.
- `lib/remote.sh` keeps the payload bytes and recipe streams unchanged; the result channel is one marked line emitted by the child and captured by a pass-through tap, never payload content.
- `lib/runbooks.sh` supplies application identity, clean commit, stable step ID, selected phase, the commit-drift gate, and manifest updates.
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

A non-empty value is validated with the frozen package-instance component rule and becomes the instance for that package in the expected graph, result, state path, and claim.

A package without `.package-instance` rejects any attempted non-default identity.

The recipe receives the same already-forwarded variable and needs no new function signature.

After resolution, the context records one sorted `package.<package>.instance` field for every precomputed top-level package and dependency.

The result writer and operator-side reconciler read that same identity instead of recomputing it from mutable environment state.

These are per-package identity fields, not per-package value views, so ADR-024's one global value namespace remains unchanged.

The framework-owned result file and marked line are not package-instance inputs.

## Commit provenance and executed-code identity

Two facts are kept separate and both are proved:

- the local commit the operator dispatched from;
- the remote checkout commit whose recipe actually ran.

Remote hosts run code from GitHub, not the local checkout, so a clean local HEAD alone proves nothing about what executed.

The remote child Cloudify process reports, inside its result body:

- `checkout_commit`: the 40-hex HEAD of the checkout it executed, or null when it cannot be determined;
- `checkout_dirty`: true when that checkout has uncommitted changes.

Rules for a newly written successful `applied` object:

- An application dispatch requires `checkout_commit` equal to the proved clean local commit recorded in its manifest and `checkout_dirty: false`.
  The applied commit is that shared 40-hex value.
- A direct package dispatch records `checkout_commit` when the remote tree is clean.
- A dirty or unidentified remote tree, local or remote, never fabricates a commit: the applied object records `application_commit: null` with `development_override: true`.
- An executed-commit mismatch on an application dispatch (`checkout_commit` differs from the manifest commit, or the remote tree is dirty) degrades the dispatch before any applied write: the event records the executed commit from the body, `applied` is left unchanged, and the run is marked degraded.
  The remote mutation already happened and is never claimed as rolled back.
- Registry migration alone writes `application_commit: null` through the same `development_override` rule below, with its migration origin carried by its event.

The package-state `applied` object therefore gains a `development_override` boolean in step 4.1, with one schema rule mirroring the manifest: `application_commit` null requires `development_override: true`.

Migration, direct commands, and development-override application runs all use that one uniform rule.

The manifest and run schemas keep their existing nullable-commit and override fields unchanged.

This supersedes the recovery plan's R3 wording that reserved a null applied commit to migration alone; the supersession is listed in Gate conditions.

## Schema changes before writers

The state and event substrate step (4.1) changes schemas and fixtures before adding a package-state writer.

### Package state

Tighten `schemas/v1/package-state.schema.json` so:

- `applied` gains `development_override` (boolean) and one `allOf` rule: `application_commit` null requires `development_override: true`;
- `applied.event_id` is a non-null event ID whenever `applied` is an object;
- `last_attempt.event_id` is a non-null event ID whenever `last_attempt` is an object;
- `health.event_id` is always a non-null event ID;
- every claim has a non-null `event_id`;
- a missing state has conceptual revision 0, but the first persisted state has revision 1.

A new or migrated state with no verification uses `health.status: unknown`, `checked_at: null`, and the event ID that created the state.

A nullable `last_attempt` remains valid because migration is not a package attempt.

Update every package-state valid fixture to use non-null event IDs.

Add invalid fixtures for null event IDs in applied, last attempt, health, and claims, and for a null applied commit without `development_override: true`.

The migrated-observation fixture gets its migration event ID, keeps `application_commit: null`, and sets `development_override: true`.

### Events

Extend `schemas/v1/event.schema.json`:

- add an optional `development_override` boolean, with an `allOf` rule: `application_commit` null with an application tuple present requires `development_override: true`;
- add one explicit registry-migration shape instead of encoding migration as install.

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

Add valid and invalid migration-event fixtures, including a missing origin, a non-absolute source path, a bad source digest, migration with a non-null application phase, and an application event with a null commit but no development override.

Keep `bash schemas/v1/validate.sh` green before any writer code.

## One context projection

Projection reads the existing context once and never reads a value source again.

ADR-024 makes resolved values dispatch-global; the projection stays one resolution.

Two projections come from one parsed context so they can never classify the same name differently:

- the record projection, used for `applied.values` and `last_attempt.requested`: every resolved context name;
- the claim projection: only the names declared by the claimed package itself (its `.remote-vars` declaration), resolved from the same context.

The claim projection implements REDESIGN's "every configuration-affecting declared value" as the values the package itself declares.

It needs no second walk: declaration names come from the enumeration the context build already performed, and values come from the context.

An unrelated dispatch value, such as one package's password while a shared dependency installs, never enters another package's claim, so compatible deployments can share that dependency.

A software package that reads a value declared only by the configuration package that pulls it is still protected: that value is claimed by the configuration package's own state subject, whose claim comparison catches the conflict.

For each `value.<NAME>` block, decode the `t:` or `b:` transport in `raw` once.

Produce these package-state fields:

- Non-secret literal: `source_form` is the decoded raw form, `reference: null`, `digest: null`, `redacted: false`.
- Secret reference: `source_form` and `reference` are the reference text, `digest: null`, `redacted: false`.
- Literal secret: `source_form: null`, `reference: null`, the existing sha256 digest, and `redacted: true`.
- Every value carries the context's `secret` and `declaration` fields.

The record projection populates `last_attempt.requested` for every result, `applied.values` after a successful install or reconfigure, a new claim's `values` restricted to the claim projection, and the claim-projection subset of a successfully reconfigured sole claim.

Produce these event fields:

- map context source `environment` to schema source `caller`;
- preserve `deployment`, `application`, `package`, `global`, and `recipe`;
- use `applied` when phase-specific resolution seeded the value from successful state;
- carry `secret` and `declaration`;
- carry a secret reference or literal-secret digest, never both;
- carry neither for a non-secret;
- never carry `source_form`, `raw`, or resolved runtime plaintext.

The projection fails closed on a missing field, malformed raw transport, inconsistent secret metadata, unknown source label, or secret literal without a digest.

Event `values` carry the same projection the transition used, restricted the same way.

## IDs, writer identity, and validation

Run and event IDs use one shared collision-resistant helper producing the schema's sortable form:

```text
YYYYMMDDTHHMMSSZ-<8 lowercase random hex>
```

The suffix comes from four bytes read from `/dev/urandom` with existing base-system tools.

Creation retries with a new suffix on collision.

It never overwrites an existing ID.

Phase 4 generates event IDs only.

Application events and claims carry `run_id: null` because the run writer does not exist until Phase 6; fabricating a run ID that no run record will ever back is forbidden.

Phase 6 wraps its new run writer around the already-stable ID format, and manifest `last_run_id` stays null until then.

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

The event create primitive is fixed now, not chosen during implementation:

1. Render one complete JSON event into a mode-0600 temporary file in the destination directory.
2. Validate it against `event.schema.json`.
3. Flush it to disk.
4. Create the final name with a hard link (`ln "$tmp" "$final"`), which is the atomic create-if-absent operation and fails when the name exists.
5. On an existing-name failure, generate a new event ID, re-render, and retry, bounded at three attempts, then die loudly.
6. Remove the temporary file after a successful link.
7. Never edit or replace a committed event.

A crash between link and temporary-file removal leaves a stray temporary holding the same bytes as the committed event; the next writer ignores it and the state-check surface reports strays in Phase 6.

A package-state transition runs under the host lock:

1. Read and validate the current state, or use conceptual revision 0 when no file exists.
2. Refuse the transition when state points to a missing event.
3. Derive the complete next state from the current state, the validated result, and the one context projection.
4. Set `next_revision = current_revision + 1`.
5. Render the event with `previous_revision = current_revision` and `resulting_revision = next_revision`.
6. Put that event ID on every state object created or changed by this transition.
7. Render and validate the complete next state into a mode-0600 temporary file in the state directory.
8. Atomically create the immutable event.
9. Atomically replace `state.json` with the validated next state.
10. Re-read the committed revision and event ID before reporting success.

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
- replaces `applied` with the proved commit or the override rule, `package_version: null`, projected values, time, and event ID;
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

A direct uninstall of a claimed package is blocked while any deployment claim exists.

The only override is the claim-release override in Claims and phase decisions.

## Expected dependency graph and reconciliation

Before taking the host lock, Cloudify expands the same static top-level and `pkg_depends` graph used to build the context.

One graph row contains:

- immediate parent package, or null for a top-level package;
- package name;
- resolved package instance;
- selected phase;
- operation kind;
- stable step identity when present.

The graph is written to a mode-0600 private file.

Membership is the reconciliation key: `(package, package_instance, phase, command_kind)`.

Reconciliation rules after the result body is fully validated:

- Every requested top-level package must appear in at least one result with its graph identity.
- Every result must match at least one graph row by membership; a result with no matching row rejects the whole body before any commit.
- The same membership may appear in several results, because one package can be pulled through several parents at runtime; each extra result commits as its own ordered attempt.
- A conditional dependency that is in the static graph but is not executed at runtime produces no result and no state transition, and blocks nothing: only requested top-level packages are required to report.
- Results commit in body order, which is execution order, under the same host lock, each with its own event and revision.

No attempt ordinal or edge ID is added: body order plus membership is the complete reconciliation contract.

## Result channel: one marked line in the streamed log

This channel supersedes the drafted framed stdout tail, its nonce machinery, and the second-SSH-exec fetch; the supersession was consented on 2026-09-15 and is recorded in Gate conditions.

First principle: the live streamed log is what makes a remote install feel like a local one.
Output is written on the remote host and streams live to the controller through one chain: the payload's `exec > >(tee -a "$CLOUDIFY_LOG_FILE") 2>&1`, the SSH channel, the local host-prefix stages, and the local protected log.
That chain must keep flowing unbuffered, unfiltered, and unbroken; it is now a documented fragile invariant in `docs/FRAGILE.md`.

The result is one line, marked by the child itself, and captured by a tap that removes nothing:

- The remote child Cloudify process aggregates per-package results into one private mode-0600 file during its run; recipe `exit`, dependency failure, or verification failure cannot bypass it.
- At its own exit, after all package work is done, the child prints exactly one line to stdout:

```text
__CLOUDIFY_RESULT_V1__ 1 <base64-body-without-wrap>
```

- The emission lives inside the child process, so the payload template, the eight byte-exact payload goldens, recipe stdin, and recipe stdout are untouched.
- The marked line flows through the existing chain like any other line: the operator sees it live and both logs keep it.
- The operator-side worker appends one pass-through capture stage to the received stream: a line-oriented filter that prints every line onward unchanged and additionally copies lines whose body after the host prefix starts with the marker into a private capture file.
  No stage may exit early or close the pipe: an early-exiting stage SIGPIPEs the chain and kills live output.
- When the SSH channel closes, the worker validates the capture: exactly one marker line, protocol version 1, well-formed unwrapped base64, valid JSON under the result contract, at most 1 MiB of body, and the staleness rule on `finished_at`.
- Zero marked lines, or more than one, marks the dispatch degraded; nothing is committed from an unvalidated body.
- The child removes its private result file after printing; a crashed child's stray file is inert and never read.

The body is JSON, is not a persisted v2 artifact, and gets no file under `schemas/v1/`.

`lib/results.sh` owns one jq validator used by the worker.

The compact body is:

```json
{
  "protocol_version": 1,
  "child_exit_status": 0,
  "finished_at": "2026-01-01T10:11:12Z",
  "checkout_commit": "0f1e2d3c4b5a69788796a5b4c3d2e1f009182736",
  "checkout_dirty": false,
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
- `finished_at` is the child's UTC completion time.
- `checkout_commit` and `checkout_dirty` follow Commit provenance and executed-code identity.
- Normal Phase 4 writes set package-state `package_version` to null because no recipe-version reporter exists.
- No value, environment snapshot, stdout, stderr, payload, path, nonce, claim, or free-form summary is allowed.
- Every object has exactly these fields.
- The body is at most 1 MiB.

Staleness: the worker rejects a body whose `finished_at` predates the worker's own dispatch start minus five minutes of clock-skew slack, treats it as a crashed predecessor's leftover, and marks the dispatch degraded.

Local dispatches use the same body file and validator, with the local child writing the file and the worker reading it directly; no marked line is needed on the local path.

The recipe remains trusted code and can inspect inherited process state as root.

This channel prevents accidental output collisions and ordinary framework ambiguity.

It is not a security boundary against a hostile remote root.

## Executed-code check

Before the first result commit, the worker compares the body's `checkout_commit` and `checkout_dirty` against the dispatch's proved local commit.

- Application dispatch: mismatch or dirty remote tree means the recipe that ran is not the manifest's commit. The dispatch is degraded, the event records the executed commit from the body, and no `applied` write or claim happens for any result in that body. `last_attempt` and health still record the attempt.
- Direct dispatch: the body's checkout facts are recorded per Commit provenance; a dirty tree yields `application_commit: null` with `development_override: true`.

The worker never writes the local HEAD as the applied commit when the body proves a different one.

## One host lock

A local dispatch worker, which is the operator-side parent of the local or remote package child, owns the host mutation lock.

It acquires the lock before reading claim compatibility or starting remote execution.

It holds the same lock through payload execution, result-line capture, body validation, graph reconciliation, the executed-code check, every package event creation, and every package-state replacement.

It releases the lock only after all committable results finish or a failure is recorded.

No package or dependency acquires another lock.

The lock wait defaults to the existing bounded state timeout and remains configurable through `CLOUDIFY_LOCK_TIMEOUT`.

After acquisition, the holder writes bounded non-secret metadata into the locked file:

- writer host;
- boot ID;
- PID and process start ticks;
- acquired time;
- durable host key.

A timeout prints that metadata and the waited duration.

The metadata is diagnostic only and does not decide lock ownership.

`flock` decides ownership.

The runbook parent updates the deployment manifest only after every host worker has exited and therefore released its host lock.

Manifest updates continue under the separate per-deployment lock.

The manifest projection is fixed:

- success: status per the existing install-plus-verify rule, `last_event_id` set to the event ID of the last result committed by this dispatch's workers;
- any failure (child, fetch, validation, staleness, executed-code mismatch, or a failed result): status `degraded`, `last_event_id` still set to the last event the workers actually committed, because failed attempts also write events;
- no event committed at all: `last_event_id` unchanged;
- `last_run_id` stays null until Phase 6.

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
- the claim projection: every value the package itself declares;
- non-secrets by source form;
- secret references by reference;
- literal secrets by digest.

Conflict diagnostics name package, instance, and conflicting deployment tuples.

They print value names and comparison class only.

They never print either value, reference locator, or digest.

Claim gating is split by certainty:

- Requested top-level packages are checked under the host lock before recipe code, because their decision decides whether anything runs at all.
- Dependencies are checked when their result commits, after execution. A dependency that turns out incompatible is marked degraded with its event, and no claim is added; the mutation already happened and is never claimed as rolled back.
- A runtime-optional dependency that never executes is never gated, so a lexical `pkg_depends` line inside an untaken branch cannot fail an unrelated dispatch.

Install decisions for checked subjects under the host lock are:

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

### Commit-drift gate

Until Phase 7 proves pinned remote execution, `app reconfigure` and `app teardown` fail loudly before any step unless the current checkout's proved commit equals the manifest's `application_commit` and the tree is clean.

This is REDESIGN's commit-drift rule applied at Phase 4, not a new policy.

The error names both commits and states that upgrade or migration is not available yet.

### Claim-release override for direct uninstalls

A direct uninstall of a package instance with active deployment claims requires all of:

- `CLOUDIFY_BREAK_CLAIMS` set exactly to the package instance being broken (a typed confirmation, not a boolean);
- every displaced claim named in its own event, each with that claim's deployment tuple, step ID, and the subject identity;
- one claim-releasing state transition per displaced claim, followed by the uninstall transition.

Without the variable, direct uninstall fails and prints the blocking deployment tuples.

The override is never valid for application teardown, which releases only its own claims.

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

The migration step (4.7) consumes those moved input fixtures and the narrow old-format reader tests.

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
3. `applied.application_commit: null` with `development_override: true`, linked to that event;
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
- invalid package or instance component;
- missing schema or validator;
- malformed context or projection;
- unresolved required redacted secret;
- claim conflict on a requested top-level package;
- host-lock timeout;
- commit drift on reconfigure or teardown;
- missing `CLOUDIFY_BREAK_CLAIMS` confirmation.

The following may occur after remote mutation and therefore mark the deployment degraded without claiming rollback:

- child process failure;
- result-line capture or validation failure;
- stale result body;
- executed-code mismatch on an application dispatch;
- unexpected reported membership or a missing requested top-level result;
- dependency claim incompatibility found at commit time;
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
- A null applied commit without `development_override: true` fails; with it, passes.
- An application event with a null commit and no override fails; with the override, passes.
- Migration event origin is required and bounded.
- Normal events reject a migration origin.
- Plain, escaped-at, multiline, reference-secret, explicit literal-secret, heuristic literal-secret, empty, spaces, quotes, colons, and shell metacharacters project correctly.
- State and event projections come from a context after every value source is made unavailable.
- The claim projection contains only the claimed package's declared names; the record projection contains all resolved names.
- No literal fixture secret appears in state, event, result body, stdout, debug output, or log.

### Event and state writes

- Invalid components and missing jq/schema create no directory or lock.
- A state file is real JSON and validates before replacement.
- An invalid next state leaves the prior bytes unchanged.
- Event creation failure leaves state unchanged.
- An existing event name causes ID regeneration, never overwrite.
- A stray event temporary with committed bytes is ignored by writers.
- State replacement failure leaves one detectable event-to-state gap.
- State pointing to a missing event is reported and blocks mutation.
- Two successive results produce revisions 1 and 2 with matching event links.
- A failed attempt preserves applied bytes and claims.

### Package instance and host identity

- No marker defaults to `default`.
- A declared instance variable selects a validated non-default instance.
- A non-default instance without recipe support fails before mutation.
- Node and instance targets produce distinct durable keys and state roots.
- Two aliases of one inventory host produce one host lock.
- An external target fails before remote execution.

### Locking and result channel

- Same-host workers serialize remote execution, fetch, and all result commits.
- Different-host workers can overlap.
- Dependencies acquire no nested lock.
- Timeout is bounded and prints the current holder metadata.
- The host lock is released before the manifest lock is acquired.
- The payload bytes stay byte-identical to all eight goldens with the result channel active.
- Recipe stdin and recipe stdout bytes are unchanged by the result channel.
- Local results land in the private file; the remote result is the one marked line on the stream, kept in both logs like any other line.
- A top-level and nested dependency report parent, package, instance, phase, operation, status, verification, checkout facts, and no values.
- Recipe success, return failure, `exit`, dependency failure, and verify failure each produce one accurate result line emitted at the child's own exit.
- A missing, duplicated, malformed, overlarge, or stale result line marks the dispatch degraded and commits nothing.
- The capture tap passes every non-marker line through in order and never terminates the stream early.
- A result whose membership is absent from the graph prevents every commit from that body.
- A missing requested top-level result fails; an extra repeated membership commits as an ordered attempt.
- A successful dependency result commits even when a later top-level result fails.
- An executed-code mismatch on an application dispatch records the executed commit in its event, writes no applied, and degrades the dispatch.
- A partial multi-package commit keeps earlier event/state pairs valid and the manifest degraded with the last committed event ID.

### Claims, phases, provenance, and migration

- Compatible claims share one state record.
- A dispatch value declared only by another package never enters a dependency's claim, and two deployments with different such values still share the dependency.
- Conflicting explicit input fails before recipe code and prints no secret material.
- Existing-claim install skips install and verifies.
- Failed first install adds no claim.
- Failed reconfigure preserves applied and claim values.
- A dependency found incompatible at commit time degrades the dispatch and adds no claim.
- An optional dependency never executed blocks nothing.
- Shared teardown releases one claim without uninstall.
- Failed last-claim uninstall preserves the claim and applied state.
- Successful last-claim uninstall clears applied and the claim.
- Direct uninstall over claims fails and prints the blocking tuples.
- Direct uninstall with `CLOUDIFY_BREAK_CLAIMS` set to the instance releases each claim with its own naming event, then uninstalls.
- Reconfigure and teardown fail on commit drift, naming both commits, before any step.
- Verify and teardown seed only from successful applied values.
- A failed attempt never seeds another phase.
- Migration dry-run writes nothing.
- Migration apply writes event first, then revision 1 state with null commit, override true, and no claims.
- Repeating identical migration is a no-op.
- Conflicting migration fails without exposing values.
- External and removed records are reported but not migrated.
- Runtime searches find no old-registry reader caller outside the migration command.

No implementation test may weaken the byte-exact payload goldens or a fragile-surface pin.

## Implementation sequence

### 4.1 State and event substrate

1. Add red schema fixtures and projection tests.
2. Add the flat context declaration-origin and package-instance fields under the fragile-surface gate.
3. Generalize the one jq schema validator.
4. Add the shared ID helper and writer-identity helper.
5. Add immutable event rendering and hard-link creation.
6. Add physical package-state rendering and event-first replacement.
7. Add subject-level gap detection.

No package-state writer lands before step 5 is complete and green.

### 4.2 Package instance and host identity

1. Add the `.package-instance` contract and tests.
2. Resolve instance identity from the already-built context.
3. Add inventory host key, host root, state path, and host-lock path helpers.
4. Reject external durable state.

### 4.3 Host lock and result channel

1. Freeze the lock, result-body, capture-tap, staleness, and graph-reconciliation tests.
2. Add the operator-side dispatch worker and bounded host lock.
3. Add framework result emission around package attempts, the child's private result file, and the marked-line emission.
4. Add the pass-through capture tap, whole-body validation, and executed-code check.
5. Validate the whole result body before ordered commits.
6. Delete the runtime registry writer and split its goldens.
7. Prove unconditional context cleanup and byte-identical payloads.

The result-line format was consented on 2026-09-15; the streamed-logging chain is a documented fragile invariant and its gate runs on this slice.

### 4.4 Phase-specific resolution

1. Add applied source forms below explicit reconfigure sources.
2. Seed verify and teardown from applied only.
3. Require matching resupply for redacted literals.
4. Keep install defaults from reinterpreting an existing claim.

### 4.5 Claims and adoption

1. Add pre-mutation compatibility checks for requested top-level packages under the host lock.
2. Add commit-time compatibility checks for dependency results.
3. Add claim-only and verify-only execution-plan decisions.
4. Add claims only after compatible success or adoption.
5. Add guarded configure-based adoption.

### 4.6 Teardown, override, and failure state

1. Add shared claim release without uninstall.
2. Add last-claim uninstall ordering.
3. Add the `CLOUDIFY_BREAK_CLAIMS` override with per-claim events.
4. Add the reconfigure and teardown commit-drift gate.
5. Preserve applied and ownership on failure.
6. Record degraded or unknown health through event-backed transitions.

### 4.7 Migration and phase gate

1. Consume the old registry bytes moved into migration fixtures in step 4.3.
2. Add the narrow old-record reader and dry-run command.
3. Add idempotent event-first apply for inventory hosts.
4. Run focused suites, one real shared-dependency case, lint, full unit, and the Phase 4 E2E scenarios.
5. Obtain final SPEC and Technical implementation reviews before the phase commit.

## Gate conditions

Consent was given by Rachid on 2026-09-15, recorded in `LOGS.md`, for:

- the result channel: one marked line emitted by the child itself on the existing streamed log, superseding the drafted framed stdout tail, its nonce, its byte parser, and the second-SSH-exec fetch; the streamed-logging chain becomes a documented fragile invariant;
- the uniform `development_override` rule for every null applied commit;
- the claim projection over the package's own declared values, recorded as ADR-025 with the REDESIGN sentence in the same commit;
- the `CLOUDIFY_BREAK_CLAIMS` override contract;
- the fragile-surface format changes: the two added flat-context field shapes and the result-line format.

The design gate (R3) is complete only after:

- fresh independent SPEC and Technical reviews return `PASS` with file and line evidence on this revision;
- the alignment that depends on those reviews alone (none currently open) lands with the reviews' evidence.

The alignment that does not depend on the reviews - REDESIGN sentence, ADR-025, the recovery plan supersessions, and `docs/FRAGILE.md` - lands in the same commit as the consent record, before code.

This turn performs no implementation.
