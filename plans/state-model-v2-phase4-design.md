# Phase 4 design: per-node deployment capture, installations, and the shared-installation guard

Status: draft, revision 1 of the redone design, under ADR-026.

The previous design (revision 9, superseded) was redone because its geometry departed from standing agreements; this document re-derives the same phase under the corrected authority.

This document authorizes no code until Rachid approves it and the review rounds return `PASS`.

## Outcome

Walking a node's ivps tree answers what runs on it: one human-readable directory per deployment, per node.

Every deployment that touches a host captures what it did there, per package it covers.

Every package instance on a host has one installation record, which holds the physical truth - what was last applied, its health and revision - and which deployments rely on it.

Two deployments relying on one installation cannot silently break or remove each other's.

Every capture change is one immutable event first, then the capture update.

## Authority and scope

This design derives from:

- ADR-026 (deployment-first per-node capture) - the geometry decision;
- ADR-021 point 8 (immutable ivps ids, now work) and ADR-022, ADR-023, ADR-024, ADR-025 where ADR-026 did not supersede them;
- REDESIGN.md as aligned to ADR-026 (per-node capture, cross-host glue, deployment capture and the shared-installation guard, write protocol);
- `schemas/v1/` (to be reshaped by step 4.1 under this design);
- the flat dispatch-context contract in `lib/context.sh`;
- the Phase 4 requirements in `plans/state-model-v2-recovery.md` (its Phase 4 checklist is redone with this design).

Phase 4 includes:

- per-node deployment capture and installation records;
- immutable event and capture-write machinery;
- deployment naming and matching;
- package-instance identity;
- one host mutation lock;
- the marked-line result channel on the streamed log;
- phase-specific resolution;
- the reliance guard, adoption, and the uninstall override;
- the commit-drift gate;
- one temporary old-registry migration command;
- deletion of the runtime registry writer.

Phase 4 does not include:

- the roadmapped JSON dispatch context;
- run-record persistence or interrupted-run classification;
- external-host durable state before SSH host-key acceptance;
- pinned historical execution beyond the drift gate;
- the adapter seam for infra tools other than ivps (future work);
- event replay or multi-operator coordination.

## Geometry: the per-node tree

For an ivps node or instance, the capture root is the directory returned by `ivps node path <node>` (plus the instance segment).

Two human-readable trees live there:

```text
<capture-root>/deployments/<application>/<flavor>/<deployment-name>/<package>/<package-instance>.json
<capture-root>/pkgs/<package>/<package-instance>/state.json
```

- `deployments/` is the architecture view: walking it answers what runs on the node and what each deployment configured.
- `pkgs/` is the physical view: one installation record per package instance on the node, holding the physical truth and the reliances.

One framework-owned file sits beside them, never parsed by ivps:

```text
<capture-root>/cloudify/.host-mutation.lock
```

A deployment that touches several hosts writes its capture on each host under the same deployment name; the cross-host glue in the manifest binds them.

A node rename does not move anything: paths follow `ivps node path`, and the durable identity inside every record is the immutable ivps id, so a renamed node keeps its history.

## Deployment identity and matching

The deployment id is the deployment name.

- Human-set through `--name`: that name is the deployment, forever.
- No name: generated as `<application>-<flavor>-<UTC-timestamp>[-suffix]`.

The same name is the same deployment.

The id is chosen at first run, recorded in the deployment manifest, and reused unchanged on every host the deployment touches.

Matching decides what a run with no name does:

- The run resolves its values once, through the ordinary dispatch context.
- It matches against the existing deployments of the same application and flavor by resolved value source forms plus resolved target bindings.
- A match converges that deployment: same capture, no new artefact.
- No match: a new deployment is created with a generated id, and the created name is printed clearly.

An explicit name never matches: it always means that deployment.

Same name with changed desired inputs is one deployment whose inputs updated in place; the change is applied by reconfigure semantics.

Capture units are not runtime counts.

The software decides how many runtimes exist; the capture is a naming discipline that never merges what the operator separated by name and never forks what the operator left identical.

## Package instances

The instance key is part of the package's configuration: `default`, or the value of the recipe-declared instance variable.

The same configuration is the same installation; a different configuration is a different installation.

Instance keys are never time-generated, because identical configuration must always find the same installation - that is what makes sharing the default and parallel runtimes opt-in.

After resolution, the context records one sorted `package.<PACKAGE>.instance` field for every precomputed top-level package and dependency, and the capture and result machinery read that identity from the context.

## Commit provenance and executed-code identity

Two facts are kept separate and both are proved: the local commit the operator dispatched from, and the remote checkout commit whose recipe actually ran.

The remote child Cloudify process reports, inside its result body: `checkout_commit` (40-hex or null when undeterminable) and `checkout_dirty`.

Rules for a newly written successful `applied` object:

- An application dispatch whose manifest records a proved commit requires `checkout_commit` equal to it and `checkout_dirty: false`; the applied commit is that shared 40-hex value.
- An executed-code mismatch on such a dispatch (differing commit, or dirty remote tree) degrades the dispatch before any applied write: the event records the executed commit from the body, `applied` is left unchanged, and the run is marked degraded. The remote mutation already happened and is never claimed as rolled back. When the body's executed commit is null or undeterminable, the degraded event records `application_commit: null` with `development_override: true` and a summary naming the undeterminable checkout.
- An application dispatch whose manifest commit is null (a development-override run) has no pinned expectation: the executed-code check is vacuous for it and never degrades on mismatch. Its applied object records `checkout_commit` when the remote tree is clean, and `application_commit: null` with `development_override: true` when it is dirty or unknown.
- A direct package dispatch records `checkout_commit` when the remote tree is clean, and null with the override flag when it is dirty or unknown.
- Registry migration writes `application_commit: null` with `development_override: true`, with its migration origin carried by its event.

The worker never writes the local HEAD as the applied commit when the body proves a different one.

## What the two records hold

The installation record (`pkgs/<package>/<package-instance>/state.json`) holds the physical truth of one package instance on one node:

- `schema_version`, host (address), host key (immutable ivps id), package, package instance;
- a monotonically increasing `revision`, changed only together with an event;
- `applied`: last successful result - package version, application commit, source-form values, time, event ID;
- `last_attempt`: the most recent attempt by any deployment or direct command - phase, requested value metadata, outcome, time, event ID;
- `health`: the last verification result - status, time, event ID;
- `reliances`: which deployments rely on this installation, each with application, flavor, deployment name, runbook step, requested values in comparable form, and the event that recorded it.

The deployment capture (`deployments/.../<package>/<package-instance>.json`) holds what this deployment did with that package:

- the deployment identity and the runbook step that owns the work;
- the reliance: which installation it uses, the requested values in comparable form, since when, and the event that recorded it;
- this deployment's last attempt for the package: phase, outcome, time, event ID.

One package instance on a node has exactly one installation record, so sharing is representable and the guard has a single place to hold.

The deployment capture never copies `applied` or `health`: the installation record is their only home, so two deployments sharing an installation cannot hold drifting copies.

## The shared-installation guard

A deployment may start relying on an installation only when its requested configuration is compatible with what the installation holds and with every reliance already recorded.

Compatible means the package and package-instance identity, the applied recipe or package version, and every configuration-affecting declared value match.

The compared values are the values the package itself declares (its `.remote-vars` names), taken from the one dispatch context; a value declared only by another package is recorded by that package's own reliance, so conflicts surface there.

Non-secret values compare by source form, secret references compare by reference, literal secrets compare by digest.

In Phase 4 the version element is vacuous (`package_version` is null and reliance records store no commit); the Phase 7 version reporter populates it later.

A conflict fails before mutation and names the deployments in conflict.

Diagnostics print value names and comparison class only - never either value, a reference locator, or a digest.

Teardown releases every reliance owned by the deployment, including dependency work without authored uninstall steps.

The pinned teardown phase decides which installations are actually uninstalled.

An installation nobody relies on remains installed unless the pinned teardown phase explicitly names it.

The package is uninstalled only when nothing relies on it anymore and the application teardown asks for uninstall.

A force flag may override the guard only with a destructive confirmation and an event naming every displaced reliance.

## Decision rules under the guard

Before recipe code runs, the worker decides, per requested top-level package, under the host lock:

- Missing installation: run install; the reliance is recorded only after success.
- Installation present with `applied: null` and no reliance (what a failed first install leaves behind): run install; the reliance is recorded only after success.
- This deployment already holds the reliance and no explicit input differs: skip install and run verify.
- Another deployment holds the reliance and everything matches: the reliance for this deployment is added without recipe mutation.
- This or another deployment holds the reliance and explicit input differs: fail before recipe code and direct the operator to reconfigure or upgrade.
- No reliance and explicit input differs from `applied`: the state is incompatible - require `--adopt`, require configure support, run configure, and record the reliance only after success.

Dependencies are not prechecked: their compatibility is checked when their result commits, after execution.

An incompatible dependency is marked degraded with its event and records no reliance; the mutation already happened and is never claimed as rolled back. Its transition follows the failed-attempt rules: `applied` preserved, `last_attempt` failed, health `degraded`.

A runtime-optional dependency that never executes blocks nothing.

This commit-time gate for dependencies is the same post-execution degraded pattern REDESIGN already establishes for a runtime dependency absent from the precomputed graph; the fail-before-mutation rule applies to the subjects that were checked before recipe code.

Reconfigure requires an existing successful `applied` object and this deployment's reliance.

Its resolution order is caller, deployment, applied, application, package, global, recipe.

It fails before mutation when another reliance would become incompatible.

A successful reconfigure updates the installation's `applied` values and this deployment's reliance values in one event-backed revision.

Verify and teardown seed from `applied` source forms; a failed `last_attempt` is never a source.

A redacted literal secret must be resupplied by caller or desired inputs and must match its stored digest before remote execution.

Changed defaults do not affect an existing reliance, verify, or teardown.

### Teardown

For the last reliance on a package named by teardown, the reliance stays recorded while the uninstall recipe runs.

On success, one transition removes the reliance, sets `applied: null`, records the successful teardown attempt, and sets health `unknown`.

On failure, the reliance and `applied` are preserved, the failed attempt is recorded, and health is `degraded`.

A direct uninstall of a relied-on installation is blocked while any reliance exists.

The override: `CLOUDIFY_BREAK_RELIANCES` set exactly to the package instance being broken.

Each displaced reliance gets its own event naming its deployment tuple and step, its own release transition, then the uninstall. Application teardown never uses the override.

## Expected dependency graph and reconciliation

Before taking the host lock, the worker expands the same static top-level and `pkg_depends` graph the context build already walks, extended to emit parent-carrying rows.

One row: immediate parent (null for top-level), package, resolved package instance, selected phase, operation kind, stable step identity when present.

The graph is written to a mode-0600 private file.

Membership is the reconciliation key: `(package, package_instance, phase, command_kind)`.

Under the host lock, the pre-mutation decisions refine the graph into the decided execution plan:

- An install decision keeps the subject's rows.
- A skip-to-verify decision replaces install rows with verify rows, and the dispatch runs the verify action for it.
- A claim-only subject (reliance added without mutation) is removed from the dispatched work: the worker performs its reliance transition itself; it emits no result and is exempt from the required-report rule.

Reconciliation rules after the result body is fully validated:

- Every decided subject with dispatched work must appear in at least one result with its decided identity.
- Every result must match a decided row by membership; a result matching nothing rejects the whole body before any commit.
- The same membership may appear several results (one package pulled through several parents); each extra result commits as its own ordered attempt.
- A conditional dependency never executed at runtime produces no result and blocks nothing.
- Framework-driven pre-installs are not dispatch subjects: the `@default` package set (or `basics` under `--no-defaults`) and any package installed by the first-contact `cloudify init` branch run under a framework recording-suppression guard, emit nothing, and need no rows.
- Results commit in body order, which is execution order, under the same host lock, each with its own event and revision.

No attempt ordinal or edge ID exists: body order plus membership is the whole contract.

`lib/results.sh` owns graph expansion: it extends the context build's existing dependency walk to emit parent-carrying rows, so no third `pkg_depends` parser appears.

## Result channel: one marked line in the streamed log

The live streamed log - written on the host, streamed to the controller through the payload's `exec > >(tee -a "$CLOUDIFY_LOG_FILE") 2>&1`, the SSH channel, the host-prefix stages, and the local protected log - must keep flowing unbuffered, unfiltered, and unbroken.

It is a documented fragile invariant (`docs/FRAGILE.md`, section 3).

The remote child aggregates per-package results into one private mode-0600 file during its run; recipe `exit`, dependency failure, or verification failure cannot bypass it.

At its own exit, after all package work, the child prints exactly one line:

```text
__CLOUDIFY_RESULT_V1__ 1 <base64-body-without-wrap>
```

The emission lives inside the child process, so the payload template, the eight byte-exact payload goldens, recipe stdin, and recipe stdout are untouched.

The line flows through the chain like any other line: the operator sees it live and both logs keep it.

The worker appends one pass-through capture stage to the received stream: a line-oriented filter that prints every line onward unchanged and additionally copies lines whose body after the host prefix starts with the marker into a private capture file.

The stage's read loop keeps a final line without a trailing newline (the `IFS= read -r line || [[ -n $line ]]` idiom).

The stage owns its return discipline: every match and copy runs in condition context, the stage returns 0 unconditionally at end of input, and the ERR trap is inhibited inside its subshell, so the router's `trap cleanup SIGINT SIGTERM ERR EXIT` can never fire mid-stream.

When the channel closes, the worker validates the capture: exactly one marker line, protocol version 1, unwrapped base64, valid JSON under the result contract, at most 1 MiB of body, and the staleness rule.

Zero or several marked lines marks the dispatch degraded; nothing is committed from an unvalidated body.

Exactly one marker is achievable because the suppression guard also silences framework-internal package work: the framework sets the guard wherever it invokes package actions for non-dispatch reasons (the defaults block inside the dispatch child, the init branch's internal install). The guard travels by process environment on the remote host, never in the payload.

The child removes its private result file after printing; a crashed child's stray file is inert and never read.

Local dispatches use the same body file directly; no marked line is needed on the local path.

The body is JSON, is not a persisted artifact, and gets no file under `schemas/v1/`.

`lib/results.sh` owns one jq validator used by the worker.

The compact body:

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
- `package` and `package_instance` identify the subject.
- `phase` comes from the action in the emitter, never from the context's resolution phase: install maps to `install`, configure to `reconfigure`, uninstall to `teardown`, verify to `verify`.
- `command_kind` is `install`, `configure`, `verify`, or `uninstall`.
- `outcome` is `succeeded` or `failed`.
- `exit_status` is 0 through 255 and agrees with outcome.
- `verification` is `ok`, `failed`, or `not-run`; `verification: failed` forces `outcome: failed`.
- `child_exit_status` is 0 through 255, or null when the child was killed by a signal; success for every result with a non-zero or null status fails validation.
- `finished_at` is the child's UTC completion time.
- `checkout_commit` and `checkout_dirty` follow the provenance rules.
- Normal Phase 4 writes set package-state `package_version` to null because no recipe-version reporter exists.
- No value, environment snapshot, stdout, stderr, payload, path, claim, or free-form summary is allowed.
- Every object has exactly these fields; the body is at most 1 MiB.

Staleness: the worker rejects a body whose `finished_at` predates its own dispatch start minus five minutes of clock-skew slack, treats it as a crashed predecessor's leftover, and marks the dispatch degraded.

The recipe remains trusted code; the channel prevents accidental collisions and ambiguity, not a hostile remote root.

## Executed-code check

Before the first result commit, the worker applies the check:

- Application dispatch with a proved manifest commit: `checkout_commit` must equal it and `checkout_dirty` must be false; mismatch or dirty degrades, records the executed commit in the event, and writes no `applied` or reliance for any result in the body. `last_attempt` and health still record the attempt.
- Application dispatch with a null manifest commit: never degrades; the applied write follows the development-override rule.
- Direct dispatch: the body's checkout facts are recorded per the provenance rules.

## One host lock

The worker owns the host mutation lock at `<capture-root>/cloudify/.host-mutation.lock`.

The lock is keyed by the durable host only (the immutable ivps id); package and package instance never enter the key.

It is acquired before any reliance reading or remote execution and held through payload execution, result-line capture, body validation, graph reconciliation, the executed-code check, and every event and capture write.

It is released before the deployment manifest lock is taken; the two locks are never held together.

No package or dependency acquires another lock.

The wait defaults to the existing bounded state timeout (`CLOUDIFY_LOCK_TIMEOUT`); on timeout the holder's non-secret metadata is printed: writer host, boot ID, PID with process start ticks, acquired time, host key.

`flock` decides ownership; the metadata is diagnostic only.

After every host worker exits, the runbook parent updates the deployment manifest under the per-deployment lock.

The manifest projection is fixed (the manifest writer and renderer gain an explicit `last_event_id` parameter in this slice; today the field is only carried over):

- success: status per the existing install-plus-verify rule, `last_event_id` set to the last event the workers actually committed;
- any failure: status `degraded`, `last_event_id` still the last committed event (failed attempts also write events);
- no event committed: `last_event_id` unchanged;
- `last_run_id` stays null until Phase 6.

A test-only assertion fails if manifest lock acquisition happens while a host-lock descriptor is still held.

Different hosts use different lock files and stay parallel; two aliases of one host serialize on one file.

## One context projection

Projection reads the existing flat context once and never re-resolves a value.

ADR-024 keeps one global namespace per dispatch.

Two projections come from one parsed context so they can never disagree:

- the record projection, for `applied` values and `last_attempt.requested`: every resolved context name;
- the reliance projection, for a reliance's compared values: only the names the package itself declares.

The reliance projection implements REDESIGN's "every configuration-affecting declared value" as the values the package declares (ADR-025).

No second value walk: declaration names come from re-running the one `.remote-vars` enumerator (`cloudify_vars_declared_names`) at commit time, intersected with the context's resolved names; values come from the context. That is a declaration read, never a value walk.

Phase 4 adds two field shapes to the flat context, both derived during the existing single resolution:

```text
value.<NAME>.declaration: explicit|heuristic|none
package.<PACKAGE>.instance: <validated-instance>
```

A valid secret reference or the live `secret <NAME>` marker yields `explicit`; the marker is already parsed by the context build, and this field only surfaces that origin. The name heuristic alone yields `heuristic`; everything else yields `none`.

Phase 5 adds validation and read surface on top; it does not introduce the marker.

For each `value.<NAME>` block, the `t:`/`b:` raw transport is decoded once:

- non-secret literal: `source_form` = decoded raw, `reference: null`, `digest: null`, `redacted: false`;
- secret reference: `source_form` and `reference` = the reference text, `digest: null`, `redacted: false`;
- literal secret: `source_form: null`, `reference: null`, the sha256 digest, `redacted: true`;
- every value carries `secret` and `declaration`.

Event fields per value: source label (`environment` maps to `caller`; `applied` when phase-specific resolution seeded it), `secret`, `declaration`, a reference or digest (never both, neither for non-secrets), never `source_form`, `raw`, or plaintext.

The projection fails closed on a missing field, malformed transport, inconsistent secret metadata, unknown source label, or a secret literal without a digest.

## Immutable event and capture writes

Events live at `~/.local/state/cloudify/events/<year-month>/<event-id>.json` under the Cloudify state root: audit records are per-run history, not node architecture.

The event create primitive is fixed:

1. Render one complete JSON event into a mode-0600 temporary file in the destination directory.
2. Validate against `event.schema.json`.
3. Flush to disk.
4. Create the final name with a hard link (`ln "$tmp" "$final"`), which is the atomic create-if-absent operation and fails when the name exists, then flush the destination directory.
5. On an existing name, generate a new event ID, re-render, retry bounded at three, then die loudly.
6. Remove the temporary file after a successful link.
7. Never edit or replace a committed event.

A crash between link and cleanup leaves a harmless stray temporary; the Phase 6 state-check surface reports strays.

Every capture change runs under the host lock:

1. Read and validate the current record, or use conceptual revision 0 when no file exists.
2. Refuse when the record points to a missing event.
3. Derive the complete next record.
4. Set `next_revision = current_revision + 1`.
5. Render the event with previous and resulting revisions.
6. Put that event ID on every object the transition created or changed.
7. Render and validate the complete next record into a mode-0600 temporary file.
8. Atomically create the event.
9. Atomically replace the record.
10. Re-read the committed revision and event ID before reporting success.

No write occurs when event creation fails.

If the event exists and the replacement fails, the worker reports the repairable gap and fails the dispatch.

A record pointing at a missing event blocks mutation.

A local write failure never implies remote rollback.

Phase 4 provides subject-level checks; Phase 6 exposes the fleet report and repair command as `cloudify state check`.

## IDs, writer identity, validation

Event IDs use the schema form `YYYYMMDDTHHMMSSZ-<8 lowercase random hex>` from `/dev/urandom`, retried on collision, never overwriting.

Phase 4 generates event IDs only; events and reliance records carry `run_id: null` because the run writer is Phase 6, and fabricating a run ID no record will ever back is forbidden. Manifest `last_run_id` stays null until then.

Writer identity is read once per worker: hostname, `/proc/sys/kernel/random/boot_id`, `$$`, `/proc/$$/stat` field 22.

The existing jq-backed validator generalizes into one `cloudify_state_validate_file <schema> <file>`; manifest validation delegates to it.

Every writer checks jq, its schema, and destination prerequisites before creating any durable directory or lock.

## Schema changes before writers

Step 4.1 reshapes the schemas before any writer exists.

### Installation record (`package-state.schema.json` reshaped)

- `host_key` spelling becomes the immutable id: `ivps:<node-id>` or `ivps:<node-id>:<instance-id>` (external `ssh-sha256:<fingerprint>` arrives in Phase 5);
- `package_instance` points at the schema's own `$defs/component` (rejects `.`, `..`, edge whitespace like the frozen rule);
- `revision` minimum becomes 1 (conceptual revision 0 is absence), with an invalid revision-0 fixture;
- `applied` gains `development_override` with one `allOf` rule: `application_commit` null requires `development_override: true`;
- `applied.event_id`, `last_attempt.event_id`, `health.event_id`, and every reliance `event_id` are non-null;
- `reliances` replaces `claims`: same required fields (application, flavor, deployment, step ID, since when, run ID null in Phase 4, event ID, compared values);
- schema and `schemas/v1/README.md` descriptions updated for the uniform null-commit rule and the reliance rename.

The migrated-observation fixture gets its migration event ID, override true, an `ivps:` host key, and non-null event IDs.

### Deployment capture (new schema, `deployment-capture.schema.json`)

- `schema_version`, application, flavor, deployment name, host key, runbook step ID;
- one reliance entry: package, package instance, compared values, since when, event ID;
- this deployment's last attempt per package: phase, outcome, time, event ID;
- `additionalProperties: false`, real JSON, validated before replacement like every artifact.

### Events

- optional `development_override` boolean, with an `allOf` rule: `application_commit` null with an application tuple present requires `development_override: true`;
- amend the existing `allOf` that forces a string commit with an application tuple, so the rule above is reachable;
- the registry-migration shape: `origin` required, `phase: null` only for `command_kind: migrate-registry`, non-null registry origin required for that kind; the value-source enum gains `migration`.

Valid and invalid fixtures are added for every new rule, and `bash schemas/v1/validate.sh` stays green before any writer code.

## Registry writer removal

When the first capture writer lands, the runtime registry writer dies in the same slice:

- `_cloudify_registry_record_bg` and every runtime record path not needed by migration are deleted;
- registry bookkeeping arrays and success-path calls leave `cloudify`;
- the wait-loop context removal becomes unconditional on success and failure; the process EXIT cleanup stays the backstop; the success, failure, interruption, direct-command, and DEBUG leak proofs are preserved;
- only the narrow old-record reader used by `cloudify state migrate-registry` survives, with proof that no runtime command calls it.

`tests/unit/golden-fixtures.bats` splits in the same slice: the eight payload fixtures and their byte-exact tests stay unchanged; the registry-record fixtures move to migration-reader fixtures without recapture; the registry-writer half of the suite is deleted.

## Registry migration

`cloudify state migrate-registry` is the sole old-registry reader.

Dry-run is the default; `--apply` is required to write.

It accepts an explicit old deployment id identifying the tree to inspect, and no application mapping (the physical observation is unclaimed; the desired-input migration owns tuples).

For each inventory record with `status: installed` or `configured`, it proves only: host and immutable id from the bucket, package, instance `default`, recorded version when present, observation time when present, old source-form `var.*` values, and the old path with its sha256.

It never infers application commit, run ID, step ID, health, bindings, or history, and ignores `output.*` fields.

Each migrated value is classified by the `schemas/v1/README.md` mapping: a `@<backend>:` value becomes an explicit reference; a heuristic secret name is decoded from its `@base64:` or `@@` form first, then becomes a redacted literal with the sha256 of the plaintext; anything else stays a non-secret literal.

Migration never writes plaintext, and a record whose classification or timestamp cannot be derived is reported, not migrated.

An applied migration writes, event first: one `migrate-registry` event (revisions 0 to 1), one installation record at revision 1 (`application_commit: null`, override true), `last_attempt: null`, health `unknown` linked to the event, no reliances.

It runs under the host lock, never invokes a recipe, and leaves the old source in place.

Idempotency keys on the origin path and source digest; an identical already-migrated observation reports no change; different v2 state or a changed source fails with both paths and no values.

Phase 8 deletes the command, reader, and input fixtures at zero inventory; the event schema and already-written events stay schema version 1.

## Failure boundaries

Fail closed before remote mutation:

- no durable host identity or unresolvable local inventory;
- invalid package or instance component;
- missing schema or validator;
- malformed context or projection;
- unresolved required redacted secret;
- reliance conflict on a requested top-level package;
- host-lock timeout;
- commit drift on reconfigure or teardown;
- missing `CLOUDIFY_BREAK_RELIANCES` confirmation.

May occur after mutation - degrade, never claim rollback:

- child process failure;
- result capture or validation failure;
- stale body;
- executed-code mismatch on a proved application dispatch;
- unexpected membership or missing decided-subject result;
- incompatible dependency at commit time;
- event-create or capture-replace failure;
- a later commit failing after earlier ones committed.

Detailed output stays in the protected log; events carry fixed bounded summaries.

## Commit-drift gate

Until Phase 7 proves pinned remote execution, `app reconfigure` and `app teardown` fail before any step unless the current proved commit equals the manifest commit and the tree is clean.

A deployment whose manifest commit is null fails with a dedicated message: unreproducible until a proved run recreates it.

## Commit-provenance summary for direct commands

Direct commands have no deployment capture and no reliance.

They still write installation records: successful installs and uninstalls follow the transitions above, with the provenance rules deciding the commit or the override.

## Tests frozen before implementation

One red test at a time, in this order.

### Schema and projection

- Non-null event IDs everywhere new; null ones fail; revision 0 fails; `package_instance` rejects `.`, `..`, edge whitespace.
- Null applied commit requires `development_override: true`; application event with null commit and no override fails.
- Migration origin required and bounded; normal events reject it.
- Plain, escaped-at, multiline, reference-secret, explicit and heuristic literal-secret, empty, spaces, quotes, colons, and metacharacters project correctly.
- Projections survive every value source being made unavailable.
- The reliance projection holds only the package's declared names; the record projection holds all resolved names.
- No fixture secret appears in any capture, event, result body, stdout, debug output, or log.

### Event and capture writes

- Invalid components and missing jq/schema create no directory or lock.
- Capture files are real JSON, validated before replacement; an invalid next record leaves prior bytes unchanged.
- Event-create failure leaves the capture unchanged; an existing event name causes regeneration, never overwrite; a stray temporary is ignored.
- Replacement failure leaves a detectable gap; a record pointing at a missing event blocks mutation.
- Two results produce revisions 1 and 2 with matching event links.
- A failed attempt preserves `applied` bytes and reliances.

### Deployment naming and matching

- No name and no prior match creates a generated-name deployment, printed.
- Same configuration, no name: converges the existing deployment, no new artefact.
- Changed configuration, no name: new generated deployment.
- Explicit name: converges or updates that deployment; a different explicit name creates a separate deployment.
- Bindings are part of the match: same values, different hosts, no match.

### Package instance and host identity

- No marker defaults to `default`; a declared variable selects a validated non-default instance; unsupported non-default fails before mutation.
- Node and instance targets produce distinct immutable keys and roots; two aliases of one host share one lock.
- A bare local install requires `ivps node path local` and fails with a named error when absent.
- An external target fails before remote execution.

### Locking and result channel

- Same-host workers serialize execution, capture, and commits; different hosts overlap; no nested locks.
- Lock timeout prints holder metadata; the host lock releases before the manifest lock.
- Payload bytes stay identical to all eight goldens with the channel active; recipe stdin and stdout bytes unchanged.
- The `@default` block and an `init` internal install emit nothing; exactly one marker; results only for the decided tree.
- Missing, duplicate, malformed, overlarge, or stale lines degrade and commit nothing.
- The tap keeps a final unterminated line, never exits early, and survives the router's real ERR-trap environment.
- A result matching no decided row blocks every commit; a missing decided result fails; an extra repeated membership commits in order.
- A dependency result commits even when a later top-level result fails.
- Executed-code mismatch on a proved application dispatch degrades, records the executed commit, writes no `applied`; a development-override run records the remote commit when clean, null with override when dirty, never degrading.
- A partial multi-package commit keeps earlier pairs valid and the manifest degraded with the last committed event ID.

### Reliances, phases, provenance, migration

- Compatible deployments share one installation through separate reliances.
- A value declared only by another package never enters a dependency's compared set; differing such values still allow sharing.
- Conflicting explicit input fails before recipe code, printing no secret material.
- Existing-reliance install skips install and verifies.
- Failed first install adds no reliance; retry (state with null `applied`, no reliance) runs install and records the reliance only after success.
- Failed reconfigure preserves `applied` and reliance values.
- An incompatible dependency at commit time degrades and records no reliance.
- An optional dependency never executed blocks nothing.
- Shared teardown releases one reliance without uninstall; failed last uninstall preserves reliance and `applied`; success clears both and sets health `unknown`.
- Direct uninstall over reliances fails, naming the blocking deployments; with `CLOUDIFY_BREAK_RELIANCES` each reliance gets its own naming event and release, then the uninstall.
- Reconfigure and teardown fail on commit drift, naming both commits; a null-commit manifest fails with the unreproducible message.
- Verify and teardown seed only from successful `applied`; a failed attempt never seeds.
- Migration dry-run writes nothing; apply writes event first, then revision 1 with null commit, override true, no reliances; identical repeat is a no-op; conflicting migration fails without exposing values; external and removed records are reported, not migrated.
- No runtime caller of the old-record reader outside the migration command.

No implementation test may weaken the payload goldens or a fragile-surface pin.

## Implementation sequence

### 4.1 State and event substrate

1. Red schema fixtures and projection tests.
2. The flat context declaration-origin and package-instance fields under the fragile-surface gate, including the `cloudify_context_validate` accepted-shape extension.
3. Generalize the one jq schema validator; reshape the installation-record schema; add the deployment-capture schema.
4. The shared ID helper and writer identity.
5. Immutable event rendering and hard-link creation.
6. Installation-record and deployment-capture rendering with event-first replacement.
7. Subject-level gap detection.

No capture writer lands before step 5 is green.

### 4.2 Immutable identity, instances, and paths

1. The ivps deliverable: immutable id per node and instance, adopted by cloudify.
2. The `.package-instance` contract and tests.
3. Instance identity from the context; per-node path helpers (`deployments/`, `pkgs/`, lock).
4. Reject external durable state; ship the README or release note on the external-host suspension, the local-inventory prerequisite, the executed-commit freshness requirement, and the clock-sync expectation.

### 4.3 Host lock and result channel

1. Freeze the lock, body, tap, staleness, matching, and reconciliation tests.
2. The dispatch worker and bounded host lock; deployment matching (match, converge, create-printed).
3. Result emission around package attempts, the private file, and the marked-line emission.
4. The pass-through capture tap, whole-body validation, and executed-code check.
5. Whole-body validation before ordered commits.
6. Delete the runtime registry writer; split the goldens.
7. Prove unconditional context cleanup and byte-identical payloads.

The result-line format was consented on 2026-09-15; the streamed-log chain is a documented fragile invariant and its gate runs on this slice.

### 4.4 Phase-specific resolution

1. Applied source forms below explicit reconfigure sources; extend the context machinery to the paths that still lack it (local verify; future runbook verify and teardown dispatches).
2. Seed verify and teardown from `applied` only.
3. Matching resupply for redacted literals.
4. Install defaults never reinterpret an existing reliance.

### 4.5 Reliances and adoption

1. Pre-mutation compatibility checks for requested top-level packages under the host lock; starts only after the REDESIGN subject-scope qualifier alignment lands.
2. Commit-time compatibility checks for dependency results.
3. Reliance-only and verify-only plan decisions.
4. Reliances only after compatible success or adoption.
5. Guarded configure-based adoption.

### 4.6 Teardown, override, and failure state

1. Shared reliance release without uninstall.
2. Last-reliance uninstall ordering.
3. The `CLOUDIFY_BREAK_RELIANCES` override with per-reliance events.
4. The commit-drift gate.
5. Preserve `applied` and ownership on failure; record degraded or unknown health through event-backed transitions.

### 4.7 Migration and phase gate

1. Consume the old registry fixtures moved in 4.3.
2. The narrow old-record reader and dry-run command.
3. Idempotent event-first apply for inventory hosts.
4. Focused suites, one real shared-dependency case, lint, full unit, the Phase 4 E2E scenarios.
5. Final SPEC and Technical implementation reviews before the phase commit.

## Gate conditions

This design is accepted only when:

- Rachid approves this document in plain language;
- fresh independent SPEC and Technical reviews return `PASS` with file and line evidence on the approved revision;
- the two fragile-surface changes already flagged (the flat-context field shapes and the result-line format) hold their recorded consent, and the reconfigure ladder insert plus the `applied` source label get their own go before step 4.4;
- the next consented REDESIGN alignment carries the subject-scope qualifier for the fail-before-mutation sentence and the teardown release-after-recipe ordering;
- the REDESIGN capture-contents placement (physical truth in the installation record; the deployment capture holds the reliance and this deployment's attempt) is confirmed with this document.

No code is written before all of the above.
