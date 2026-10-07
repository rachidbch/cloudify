# Phase 4 design: per-node deployment inventory, guard, and streamed results

Status: draft, revision 8 of the redone design, under ADR-026 and ADR-027.

Revision 8 (Rachid-authorized amendments, 2026-09-17): the per-node tree is renamed from capture to **cloudify inventory** (the ivps inventory lists hosts; cloudify inventories plugged into it record deployments and packages on a host); the deployment directory gains a `packages/` segment, reserving the deployment directory for future non-package facts; events carry the source form of every non-secret value and the writing cloudify tool version, making the inventory derivable from the event log; bare direct installs become synthesized `_direct` deployments, ending out-of-band mutation; and reproduction is anchored on recorded package versions and value source forms, with the commit kept only as the provenance and drift guard.

Revision 7 (accepted by Rachid as the specification, 2026-09-17, without a further verification pass) resolves round two's Technical findings: native package-manager dependencies become named report-only subjects, migration decodes the old `@base64:` transport before classifying and never fabricates an explicit classification, the version contract is sweep-added to every recipe, and the lock and rename details are pinned.

Revision 3 resolved round one's findings; revision 4 resolves round two's findings and aligns the remaining stale authority text (default-name rules, the fragile-surface pin, the compatibility sentence, adoption) to ADR-026, so no reviewer can read a refused geometry back as authority.

Revision 1 separated an installation record from the deployment inventory; revision 2 collapses them into the single deployment tree, replaces the marked-line channel with filtered result lines, makes package version a required reported fact, reports framework work truthfully, and deletes the decision-refinement machinery.

Revision 3 resolves round one's findings: the framework inventory subject, the version reporter contract and package-wide sweep, space-free result-line fields, the enumerated REDESIGN amendments, and the migration carve-outs.

This document authorizes no code until Rachid approves it and the review rounds return `PASS`.

## Outcome

Walking a node's ivps tree answers what runs on it: one directory per deployment, one directory per package it covers, per node.

Every inventory change is one immutable event first, then the inventory update.

Every package reports its installed version; the version is required.

Two deployments relying on the same installation cannot silently break or remove each other's.

## Authority and scope

This design derives from:

- ADR-026 (deployment-first per-node inventory) - the geometry decision;
- ADR-027 (cloudify inventory naming and layout, event value content, `_direct` deployment synthesis) - the revision 8 amendments;
- ADR-021 point 8 (immutable ivps ids, now work) and ADR-022, ADR-023, ADR-024, ADR-025 where ADR-026 did not supersede them;
- REDESIGN.md as aligned to ADR-026 and amended by this document: the inventory holds the package version while the application commit lives at the deployment level; the guard does not compare versions (an amendment to the compatibility sentence); deployment names have no `default` fallback (an amendment to the naming rules); an unknown result line is a dispatch-wide refusal (an amendment to the per-subject rule);
- `schemas/v1/` (reshaped by step 4.1 under this design);
- the flat dispatch-context contract in `lib/context.sh`;
- the Phase 4 requirements in `plans/state-model-v2-recovery.md` (its Phase 4 checklist is redone with this design).

Phase 4 includes:

- the per-node deployment inventory tree;
- immutable event and inventory-write machinery;
- deployment naming and matching;
- package-instance identity;
- one host mutation lock;
- result lines on the streamed log;
- required package versions;
- phase-specific resolution;
- the shared-installation guard, adoption, and the uninstall override;
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

## Geometry: one tree per node

For an ivps node or instance, the inventory root is the directory returned by `ivps node path <node>` (plus the instance segment).

One human-readable tree lives there:

```text
<inventory-root>/deployments/<application>/<flavor>/<deployment-name>/packages/<package>/<package-instance>/state.json
```

The `packages/` segment reserves the deployment directory for future non-package facts; package state is never a direct child of the deployment directory.

Walking `<inventory-root>/deployments/` answers what runs on the node, by which deployment, with which packages and package instances.

One framework-owned directory sits beside it, never parsed by ivps:

```text
<inventory-root>/cloudify/.host-mutation.lock
```

A deployment that touches several hosts writes its inventory on each host under the same deployment name; the cross-host glue in the manifest binds them.

A node rename does not move anything: paths follow `ivps node path`, and the durable identity inside every record is the immutable ivps id, so a renamed node keeps its history.

There is no second state tree.

The inventory of a deployment is what that deployment last did with a package - not a claim about the machine's runtime truth.

The software decides how many runtimes exist; cloudify decides only what it configured, and records that.

## What one inventory record holds

`<...>/<deployment-name>/<package>/<package-instance>/state.json`:

- `schema_version`;
- the deployment identity: application, flavor, deployment name;
- the host: operator-facing address and the immutable ivps id;
- the package and the package instance;
- the runbook step that owns the work (always set by normal writes; null only for migrated inventory records);
- a monotonically increasing `revision`, changed only together with an event;
- `applied`: the last successful result this deployment applied - **version** (required), source-form values each with their resolution source (`caller` marks a set value, ADR-030), time, event ID;
- `last_attempt`: the most recent attempt by this deployment - phase, requested value metadata, outcome, time, event ID;
- `health`: this deployment's last verification observation - status, time, event ID.

The version contract (amended 2026-09-20, Rachid's ruling: packages are opaque and their devs are trusted, so the framework never probes a machine for a version): every package declares its version in a dev-owned `pkg/<name>/.version` file - one line, the package's version, charset-safe, initialized across every package to `1.0.0` and bumped by the dev when the package meaningfully changes. The framework reads the declaration, never executes a reporter; result lines carry it and the inventory stores it. A missing, empty or off-charset declaration yields `version=unknown` and the attempt is recorded as failed; native fallback subjects (no cloudify package dir) declare nothing, report `none` and are exempt. This replaces the earlier per-recipe `pkg_version()` reporter-function contract; `none` no longer exists for cloudify packages.

Versions and instance keys are space-free and restricted to the visible charset `[A-Za-z0-9._+~:-]`; anything else reports `unknown`.

The annotation sweep across every recipe in `pkg/` is part of step 4.3, before any E2E gate.

`applied` holds no commit: the recipe provenance lives at the deployment level (manifest, events), not per package.

## Host origin and continuity

ivps and the engine can mutate hosts - restore, recreate, move - so an inventory never claims "the machine is in this state".
What it claims: this inventory describes the machine that had this origin, and cloudify can detect when that machine is gone or was rewound.

At the first inventory write on a host, cloudify records two facts in the framework `cloudify/` directory beside `deployments/`, with the same immutable create-if-absent discipline as events:

- `origin`: the machine's base image fingerprint and created-at from the engine or ivps inventory, marked `discovered` (engine answered), `asserted` (operator supplied `--baseline <ref>`), or `unknown` (nothing could answer, e.g. bare metal);
- `continuity`: the immutable ivps host id plus the last-seen boot id.

Every dispatch compares the observed pair (host id, boot id) against the recorded continuity before any mutation.
A replaced machine (new instance id) or a rewound one (same id, new boot id after a snapshot restore) fails before mutation with a named message - verify or re-adoption is the operator's next move.
Cloudify never silently mutates on top of an ivps or engine act.

The origin facts come from ivps instance records (`nodes/<node-id>/instances/<instance-id>/instance.json`, ADR-028): until they exist, instance hosts have no durable identity and no origin to record.

The version is the software fact and is required: every package recipe reports its installed version, the framework queries it after every package attempt, and a missing or failing report makes the attempt failed with `version=unknown`.

`health` is this deployment's last verification observation, not the machine's truth; the machine is checked by running verify.

## Deployment identity and matching

The deployment id is the deployment name.

- Human-set through `--name`: that name is the deployment, forever.
- No name: generated as `<application>-<flavor>-<UTC-timestamp>[-suffix]`, validated against the component byte cap; the application and flavor segments are truncated to fit before the timestamp, and a name that still cannot fit fails with a named error before any write.

The same name is the same deployment.

The id is chosen at first run, recorded in the deployment manifest, and reused unchanged on every host the deployment touches.

Matching decides what a run with no name does:

- The run resolves its values once, through the ordinary dispatch context.
- It matches against the existing deployments of the same application and flavor by comparing its resolved value source forms and resolved bindings with each candidate deployment's recorded `last_attempt.requested` values and recorded bindings (a failed-first-install inventory still matches: its requested values are recorded even though `applied` is null).
- A match converges that deployment: same inventory, no new artefact.
- No match while deployments already exist: a named refusal listing them - deploying the same application twice requires naming at least one (ADR-031, amended 2026-09-21). No match with zero existing deployments: the first deployment is created with a generated id, and the created name is printed clearly.

An explicit name never matches: it always means that deployment.

Same name with changed desired inputs is one deployment whose inputs updated in place; the name is identity, not an application mechanism.

Re-running install while explicit inputs differ from `applied` still fails and directs the operator to reconfigure - REDESIGN's rule stands unchanged.

Inventory units are not runtime counts.

Application matching never crosses the `_direct` namespace: a synthesized direct deployment matches only an explicit `--name` reusing it.

The software decides how many runtimes exist; the inventory is a naming discipline that never merges what the operator separated by name and never forks what the operator left identical.

## Package instances

The instance key is part of the package's configuration: `default`, or the value of the recipe-declared instance variable.

Installing a package twice with the exact same configuration is the same package instance; a different configuration is a different package instance.

That is all cloudify can know, and it is all the inventory needs: the instance key makes sharing the default and parallel runtimes opt-in.

Instance keys are space-free and restricted to the visible charset `[A-Za-z0-9._+~:-]`, so they are always safe on a result line and in a path.

Instance keys are never time-generated.

A package declares instance support with a `.package-instance` file in its recipe directory, containing exactly the name of its instance variable; that variable must also appear in the package's `.remote-vars` declaration.

The framework validates the declared name and resolves the instance key from it.

After resolution, the context records one sorted `package.<PACKAGE>.instance` field for every precomputed top-level package and dependency, and the inventory and result machinery read that identity from the context.

## Commit provenance and executed-code identity

Recipe provenance lives at the deployment level: the manifest pins the application commit, and events record what ran.

Per-package inventory records hold the version instead - the software fact.

The remote child reports its checkout facts on their own line (`checkout v1: commit=<40-hex|unknown> dirty=true|false`), and the worker applies the executed-code check:

- Application dispatch with a proved manifest commit: the reported commit must equal it and the tree must be clean; a mismatch or dirty remote tree degrades the dispatch before any inventory write - the event records the executed commit, `applied` is left unchanged, and the run is marked degraded. The remote mutation already happened and is never claimed as rolled back. When the reported commit is null or undeterminable, the degraded event records the null commit with `development_override: true` and a summary naming the undeterminable checkout.
- Application dispatch with a null manifest commit (a development-override run): never degrades on this check; its manifest already carries the override.
- Direct dispatch: the reported commit and dirty flag are recorded in the event outcome summary fields cloudify already owns; nothing durable per package carries the commit.

The worker never writes the local HEAD as the executed commit.

## The shared-installation guard, by scan

The node's deployment tree shows which deployments rely on an installation: same package, same package instance, under other deployments.

The guard is a node-local scan of that tree.

Rules:

- Uninstall of a package instance is blocked while another deployment's inventory exists for the same package and instance. The blocker names the deployments.
- Install or configure with a configuration that differs from an existing inventory of the same package instance held by another deployment is a conflict: it fails before mutation and names the deployments in conflict. The comparison reads that inventory's `applied` values - what the other deployment last applied; when `applied` is null (a failed first install), it reads that inventory's `last_attempt.requested` values instead, so a differing requested configuration is still a conflict.
- Same configuration: no conflict - the recipe converges the same installation, and the new deployment records its own inventory.

Compared values are the values the package itself declares (its `.remote-vars` names), taken from the one dispatch context; a value declared only by another package is recorded by that package's own inventory, so conflicts surface there.

Non-secret values compare by source form, secret references compare by reference, literal secrets compare by digest.

In Phase 4 the version is recorded but not compared: a shared upgrade by one deployment is that deployment's act, and the other deployment's next verify observes the machine.

Diagnostics print value names and comparison class only - never either value, a reference locator, or a digest.

A direct package command without deployment context has no inventory and no reliance; its uninstall is still blocked by the same scan, and its installs are still conflict-checked against existing inventories.

The override: `CLOUDIFY_BREAK_RELIANCES` set exactly to the package instance being broken.

Each displaced deployment gets its own event naming its deployment tuple and step, its own inventory release, then the uninstall. Application teardown never uses the override.

## Decision rules

Recipes are idempotent by contract: re-running install is the converge.

There is no skip-install, no plan refinement, and no pre-decision of outcomes - cloudify cannot know what installing will do, and the fog is accepted.

Before recipe code runs, two node-local scans answer the only questions worth asking:

- Uninstall: does another deployment's inventory use this package instance? Block, naming the deployments.
- Install or configure: does another deployment's inventory hold a different configuration for this package instance? Conflict, naming the deployments.

Adoption is operator-asserted: `--adopt` on an install takes over an installation cloudify has no inventory for - an installation exists on the machine, but the fog makes it invisible to the scan, so the flag is the trigger, not any detection.

It requires configure support, runs configure instead of install, and records the inventory only after success.

A package without configure support refuses before mutation.

Then the recipe runs, and the result lines say what happened.

Teardown releases this deployment's inventories; the pinned teardown phase decides which packages are actually uninstalled, and the uninstall scan holds the guard.

An installation this deployment covers but teardown does not name stays installed, with this deployment's inventory removed and the machine untouched.

Dependencies actually touched by `pkg_depends` are recorded like any other package, with the deployment identity of the run that pulled them.

The remote result channel reports package identity, parent, instance, and outcome without carrying values.

The parent looks up that package's values in the precomputed dispatch context and never walks sources again.

A runtime dependency absent from the precomputed graph still reports, and its inventory fails closed: no values are invented after execution.

The classifier has three buckets: a result naming a cloudify package in the graph is recorded normally; a result naming a cloudify package absent from this dispatch's expanded graph is that dependency's own fail-closed inventory, and the run is degraded; a result naming a native subject is reconciled as report-only; a result naming anything else is a graph error, and the dispatch fails in full before any inventory write.

The router's original command-line package list is not an adequate inventory of dependency work; the result lines are.

## Expected results and reconciliation

(Amended 2026-09-20, Rachid's ruling: no recipe-text graph is computed for reconciliation. Packages are opaque and the run's own reports are the facts; the frozen static expansion, its native-subject pre-registration, and the dispatch-wide "unknown name" refusal are removed.)

The worker reconciles the collected result lines against the two fact sources it already holds: the dispatch's requested package words, and what the lines themselves report (package, parent, class).

Reconciliation after the streamed log closes:

- Every requested top-level package must have at least one result line naming it with `parent=-` (a dependency-class appearance does not satisfy the request); a gap fails the dispatch before any inventory write.
- Every result line's `parent` must be `-`, `@defaults`, `@init`, or a cloudify package name; anything else is a malformed dispatch and fails before any inventory write.
- A reported name that is not a cloudify package is a native subject: report-only, no inventory, no event, exempt from the version contract and from guard comparison. Its installation is real, and the inventory records of the cloudify packages that declared it are where its consequence is recorded. There is no dispatch-wide "unknown name" refusal: reports can only name work the run attempted, broken reports are caught by line validation, and unexpected work is recorded as observed.
- The same package may appear in several results (pulled through several parents); each extra result commits as its own ordered attempt.
- A conditional dependency that never executed produces no result and blocks nothing.
- Framework work reports truthfully and is expected: the `@default` package set (or `basics` under `--no-defaults`) on install actions, and the `required` converge from `cloudify init` on remote dispatches. Their lines carry `parent=@defaults` or `parent=@init`.
- A top-level result naming a cloudify package outside the requested words is classified `unrequested` and recorded as observed; reconciliation does not fail on it, and the worker surfaces it at commit time.
- Framework inventory subject: when the dispatch has a deployment, `@defaults` work is recorded under the run's deployment with the reserved step ID `defaults`, and init's internal install is recorded with the reserved step ID `init`. On paths with no deployment - direct commands and the init process itself - framework results report and never record an inventory.
- The reserved step IDs `defaults` and `init` are forbidden to runbook steps in validation, with fixtures, so framework attribution can never collide with authored steps.

No attempt ordinal or edge ID exists: result order plus membership is the whole contract.

## Result lines on the streamed log

The live streamed log - written on the host, streamed to the controller through the payload's `exec > >(tee -a "$CLOUDIFY_LOG_FILE") 2>&1`, the SSH channel, the host-prefix stages, and the local protected log - must keep flowing unbuffered, unfiltered, and unbroken.

It is a documented fragile invariant (`docs/FRAGILE.md`, section 3).

Results are ordinary lines in that log, keyed for filtering:

```text
result v1: parent=- package=nginx instance=default phase=install action=install outcome=succeeded exit=0 verification=ok version=1.24.0
```

- The child prints one line per package attempt, when that attempt ends - live, richer logs by construction.
- `parent` is `-` for a top-level package, the immediate package name for a dependency, `@defaults` or `@init` for framework work.
- `version` is the reported package version, or `unknown`; `unknown` forces `outcome=failed`.
- `outcome` is `succeeded` or `failed`; `exit` is the recipe's real exit status, 0 through 255 - a non-zero exit forces `outcome=failed`; `verification` is `ok`, `failed`, or `not-run`, and `failed` forces `outcome=failed`. Forced failures never alter `exit`: the line records the recipe's exit truthfully, and `outcome` is the framework's verdict.
- `phase` comes from the action: install maps to `install`, configure to `reconfigure`, uninstall to `teardown`, verify to `verify`.
- Fields are `key=value`, space-separated, no spaces in values; new fields may be appended; unknown fields are ignored by the reader.
- No value, environment snapshot, stdout, stderr, payload, or free-form text is allowed in a result line.
- At most 64 result and checkout lines per dispatch, each at most 512 bytes; exceeding either fails the dispatch.
- The child also prints its checkout facts once, before its package work: `checkout v1: commit=<40-hex|unknown> dirty=true|false`. The tap collects both keys; a remote dispatch with no checkout line treats the commit as undeterminable under the executed-code check. On first contact the init child and the dispatch child each print one: identical values are required, and the first line wins.

The payload template, the eight byte-exact payload goldens, recipe stdin, and recipe stdout are untouched: the lines are printed by the child's framework code, like any other log line.

The worker appends one pass-through result stage to the received stream: a line-oriented filter that prints every line onward unchanged and additionally copies lines whose body after the host prefix starts with `result v1: ` into a private inventory file.

The stage's read loop keeps a final line without a trailing newline (the `IFS= read -r line || [[ -n $line ]]` idiom).

The stage owns its return discipline: every match and copy runs in condition context, the stage returns 0 unconditionally at end of input, and the ERR trap is inhibited inside its subshell, so the router's `trap cleanup SIGINT SIGTERM ERR EXIT` can never fire mid-stream.

The private inventory file is created fresh for every dispatch (a unique temporary), so stale lines from earlier runs cannot enter it.

When the channel closes, the worker validates the collected lines field by field and reconciles them against the graph.

A requested top-level package with no line, or a line naming an unknown package, fails the dispatch before any inventory write.

Local dispatches write the same lines to a private temp file the worker reads directly; no stream filter is needed on the local path.

The recipe remains trusted code; the key prevents accidental collisions and ambiguity, not a hostile remote root.

## One host lock

The worker owns the host mutation lock at `<inventory-root>/cloudify/.host-mutation.lock`.

The lock is keyed by the durable host only (the immutable ivps id); package and package instance never enter the key.

It is acquired before any scan or remote execution and held through payload execution, result-line collection, reconciliation, the executed-code check, and every event and inventory write.

It is released before the deployment manifest lock is taken; the two locks are never held together.

No package or dependency acquires another lock.

The wait defaults to the existing bounded state timeout (`CLOUDIFY_LOCK_TIMEOUT`); on timeout the holder's non-secret metadata is printed - writer host, boot ID, PID with process start ticks, acquired time, host key - read from the lock file, where the holder wrote it under the held flock.

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

- the inventory projection, for `applied` values and `last_attempt.requested`: every resolved context name;
- the compared projection, for a valid inventory's guard-compared values: only the names the package itself declares.

The compared projection implements REDESIGN's "every configuration-affecting declared value" as the values the package declares (ADR-025).

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

Literal secrets do enter the dispatch context as resolved plaintext - by design: the target process needs them, the context is mode 0600 and swept on every exit, and everything durable holds only the reference, or redaction plus digest.

Event fields per value: source label (`environment` maps to `caller`), `secret`, `declaration`, a reference or digest for secrets (never both), the `source_form` for every non-secret value (secrets never carry one), never `raw` or plaintext. The inventory record's value objects carry the same source label (amended 2026-09-21, ADR-030: reconfigure seeding discriminates on it - `caller` at apply time marks a set value).
Events also carry the writing cloudify tool version.
With non-secret source forms in events, the inventory is derivable from the event log: the log is the truth, the inventory its materialized view.
Reproduction of historical values rests on these recorded forms, never on the availability of a git commit; the commit pins provenance only.

The projection fails closed on a missing field, malformed transport, inconsistent secret metadata, unknown source label, or a secret literal without a digest.

## Immutable event and inventory writes

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

Every inventory change runs under the host lock:

1. Read and validate the current inventory, or use conceptual revision 0 when no file exists.
2. Refuse when the inventory points to a missing event.
3. Derive the complete next inventory.
4. Set `next_revision = current_revision + 1`.
5. Render the event with previous and resulting revisions.
6. Put that event ID on every object the transition created or changed.
7. Render and validate the complete next inventory into a mode-0600 temporary file in the inventory's own directory.
8. Atomically create the event.
9. Atomically replace the inventory.
10. Re-read the committed revision and event ID before reporting success.

No write occurs when event creation fails.

If the event exists and the replacement fails, the worker reports the repairable gap and fails the dispatch.

An inventory pointing at a missing event blocks mutation.

A local write failure never implies remote rollback.

Phase 4 provides subject-level checks; Phase 6 exposes the cross-host report and repair command as `cloudify state check`.

## IDs, writer identity, validation

Event IDs use the schema form `YYYYMMDDTHHMMSSZ-<8 lowercase random hex>` from `/dev/urandom`, retried on collision, never overwriting.

Phase 4 generates event IDs only; events carry `run_id: null` because the run writer is Phase 6, and fabricating a run ID no record will ever back is forbidden. Manifest `last_run_id` stays null until then.

Every event records the writing cloudify tool version, read once per worker alongside the writer identity, so the audit answers which cloudify wrote it.

Writer identity is read once per worker: hostname, `/proc/sys/kernel/random/boot_id`, `$$`, `/proc/$$/stat` field 22, cloudify tool version.

The existing jq-backed validator generalizes into one `cloudify_state_validate_file <schema> <file>`; manifest validation delegates to it.

Every writer checks jq, its schema, and destination prerequisites before creating any durable directory or lock.

## Schema changes before writers

Step 4.1 reshapes the schemas before any writer exists.

### Package inventory record (`package-state.schema.json` reshaped)

The artifact becomes the per-deployment, per-package inventory record:

- `host_key` spelling becomes the immutable id: `ivps:<node-id>` or `ivps:<node-id>:<instance-id>` (external `ssh-sha256:<fingerprint>` arrives in Phase 5);
- deployment identity fields (application, flavor, deployment name) and the runbook step ID are required;
- `package_instance` points at the schema's own `$defs/component`, further restricted to the space-free result-line charset (`identity.md` carries the same rule);
- `revision` minimum becomes 1 (conceptual revision 0 is absence), with an invalid revision-0 fixture;
- the runbook step ID becomes nullable, with the migration writer as its only null producer, pinned by valid and invalid fixtures;
- `applied` holds `version` - required, space-free charset, or `null` when the recipe declares none or a migration proves none - source-form values, time, and event ID; no commit field;
- the `claims` array and its `$defs/claim` are removed (the guard is the node scan), with the README field list and fixtures updated in the same slice;
- the Phase 4 `host_key` pattern admits only `ivps:` ids - `ssh-sha256:` is never produced until Phase 5;
- `applied.event_id`, `last_attempt.event_id`, and `health.event_id` are non-null;
- schema and `schemas/v1/README.md` descriptions updated for the inventory meaning and the uniform null-commit rule.

The migrated-observation fixture gets its migration event ID (the event carries `development_override: true`; the inventory has no commit field to bear it), an `ivps:` immutable host key, null step ID, null `last_attempt`, and non-null event IDs.

### Events

- optional `development_override` boolean, with an `allOf` rule: `application_commit` null with an application tuple present requires `development_override: true`;
- amend the existing `allOf` that forces a string commit with an application tuple, so the rule above is reachable;
- the registry-migration shape: the `command_kind` enum gains `migrate-registry`; a new `origin` property is added and required only for that command kind through the conditional rule; `phase` becomes conditionally nullable for it; the value-source enum gains `migration`;
- required `tool_version` string on every event;
- value objects gain `source_form`, present only when the value is not a secret: an `allOf` rule rejects `source_form` on any value with `secret: true`, keeping references and digests as the only secret content;

Valid and invalid fixtures are added for every new rule, and `bash schemas/v1/validate.sh` stays green before any writer code.

## Registry writer removal

When the first inventory writer lands, the runtime registry writer dies in the same slice:

- `_cloudify_registry_record_bg` and every runtime record path not needed by migration are deleted;
- registry bookkeeping arrays and success-path calls leave `cloudify`;
- the wait-loop context removal becomes unconditional on success and failure; the process EXIT cleanup stays the backstop; the success, failure, interruption, direct-command, and DEBUG leak proofs are preserved;
- only the narrow old-record reader used by `cloudify state migrate-registry` survives, with proof that no runtime command calls it.

`tests/unit/golden-fixtures.bats` splits in the same slice: the eight payload fixtures and their byte-exact tests stay unchanged; the registry-record fixtures move to migration-reader fixtures without re-recording; the registry-writer half of the suite is deleted.

## Registry migration

`cloudify state migrate-registry` is the sole old-registry reader.

Dry-run is the default; `--apply` is required to write.

It accepts an explicit old deployment id identifying the tree to inspect, with the mapping flags mirroring `cloudify deployment migrate` (`--application <application> [--flavor <flavor>] [--name <deployment>]`); records whose old deployment id has no mapping are reported, not migrated.

For each inventory record with `status: installed` or `configured`, it proves only: host address from the bucket - the immutable id resolved from the inventory, with an unresolvable node reported among the not-migrated records - package, instance `default`, recorded version when present, observation time when present, old source-form `var.*` values, and the old path with its sha256.

It never infers application commit, run ID, step ID, health, bindings, or history, and ignores `output.*` fields.

The old registry re-encoded every multiline value as `@base64:...`, so that prefix is transport encoding, not a proven reference.

Migration decodes the transport first, then classifies: a heuristic secret name becomes a redacted literal with the sha256 of the decoded plaintext; anything else becomes a non-secret literal holding the decoded form.

Migration never emits an explicit secret classification, because the old record cannot prove a reference was deliberate; every decoded value is listed in the migration report so the operator can re-establish deliberate references afterwards.

Migration never writes plaintext, and a record whose classification or timestamp cannot be derived is reported, not migrated.

An applied migration writes, event first: one `migrate-registry` event (revisions 0 to 1), one inventory record at revision 1 - `last_attempt: null`, `step_id: null` (the old record proves neither), `version` from the record when present else `null`, `applied` values from the old source forms, health `unknown` linked to the event - under the mapped deployment directory.

It runs under the host lock, never invokes a recipe, and leaves the old source in place.

Idempotency keys on the origin path and source digest; an identical already-migrated observation reports no change; different v2 state or a changed source fails with both paths and no values.

Phase 8 deletes the command, reader, and input fixtures at zero inventory; the event schema and already-written events stay schema version 1.

## Failure boundaries

Fail closed before remote mutation:

- no durable host identity or unresolvable local inventory;
- invalid package or instance component;
- missing schema or validator;
- malformed context or projection;
- unresolved required redacted secret, or resupplied plaintext whose digest does not match;
- guard conflict or uninstall block found by the node scan;
- host-lock timeout;
- commit drift on reconfigure or teardown;
- missing `CLOUDIFY_BREAK_RELIANCES` confirmation.

May occur after mutation - degrade, never claim rollback:

- child process failure;
- result collection or validation failure;
- stale lines;
- executed-code mismatch on a proved application dispatch;
- a result naming an unknown package, or a missing requested top-level result;
- an incompatible dependency observed at result time;
- event-create or inventory-replace failure;
- a later commit failing after earlier ones committed.

Detailed output stays in the protected log; events carry fixed bounded summaries.

## Commit-drift gate

Until Phase 7 proves pinned remote execution, `app reconfigure` and `app teardown` fail before any step unless the current proved commit equals the manifest commit and the tree is clean.

A deployment whose manifest commit is null fails with a dedicated message: unreproducible until a proved run recreates it.

## Direct commands

Direct package commands keep their signatures and stop being out-of-band.

The application namespace `_direct` is reserved: a bare `cloudify install <pkg>` with no `--name` synthesizes a deployment under it, with a generated name (`<pkg>-<UTC-timestamp>[-suffix]`), a virtual one-step runbook whose stable step ID is `direct`, and a manifest pinned at the proved current commit - or a null commit with the uniform `development_override` rule.
The step ID `direct` joins `defaults` and `init` as reserved and forbidden to runbook steps in validation.

A bare direct install never matches: it always creates a new deployment and prints the name.
An explicit `--name` under `_direct` means that deployment, every time.

Synthesized direct deployments are ordinary deployments: full inventory and events, guard-scanned, reliance-protected, teardown through the normal deployment deletion.
Their result lines still stream into the log and their version discipline still applies.
An install by a direct command that an application deployment later makes with the same configuration converges the same installation; each deployment records its own inventory from that point on.

## Tests frozen before implementation

One red test at a time, in this order.

### Schema and projection

- Non-null event IDs everywhere new; null ones fail; revision 0 fails; `package_instance` rejects `.`, `..`, edge whitespace.
- `version` required and non-empty in `applied`; no commit field exists in the inventory.
- Application event with null commit and no override fails.
- Migration origin required and bounded; normal events reject it.
- Plain, escaped-at, multiline, reference-secret, explicit and heuristic literal-secret, empty, spaces, quotes, colons, and metacharacters project correctly.
- Projections survive every value source being made unavailable.
- The compared projection holds only the package's declared names; the inventory projection holds all resolved names.
- No fixture secret appears in any inventory record, event, result line, stdout, debug output, or log.
- Events carry `tool_version`; non-secret event values carry `source_form`; a secret value with `source_form` fails validation.

### Event and inventory writes

- Invalid components and missing jq/schema create no directory or lock.
- Inventory files are real JSON, validated before replacement; an invalid next inventory leaves prior bytes unchanged.
- Event-create failure leaves the inventory unchanged; an existing event name causes regeneration, never overwrite; a stray temporary is ignored.
- Replacement failure leaves a detectable gap; a valid inventory pointing at a missing event blocks mutation.
- Two results produce revisions 1 and 2 with matching event links.
- A failed attempt preserves `applied` bytes.

### Deployment naming and matching

- No name and no prior match creates a generated-name deployment, printed.
- Same configuration, no name: converges the existing deployment, no new artefact.
- Changed configuration, no name: named refusal listing the existing deployments (ADR-031); the byte-cap truncation still applies to the FIRST deployment's generated name.
- Explicit name: converges or updates that deployment; a different explicit name creates a separate deployment.
- Bindings are part of the match: same values, different hosts, no match.

### Package instance and host identity

- No marker defaults to `default`; a declared variable selects a validated non-default instance; unsupported non-default fails before mutation.
- Node and instance targets produce distinct immutable keys and roots; two aliases of one host share one lock.
- A bare local install requires `ivps node path local` and fails with a named error when absent.
- An external target fails before remote execution.
- Host origin lands as `discovered` when the ivps instance record answers, `asserted` with `--baseline`, `unknown` otherwise; a boot-id change on the same host id fails before mutation; a new host id fails; a rename keeps continuity.

### Locking and result lines

- Same-host workers serialize execution, collection, and commits; different hosts overlap; no nested locks.
- Lock timeout prints holder metadata; the host lock releases before the manifest lock.
- Payload bytes stay identical to all eight goldens with result lines active; recipe stdin and stdout bytes unchanged.
- `@default`, `init`, dependency, and native lines all appear, attributed; every requested top-level cloudify package reports; native subjects write no inventory and skip the version contract.
- Missing requested top-level results fail; a result naming an unknown package fails; repeated membership commits in order.
- Malformed lines (bad fields, unknown outcome, version mismatch with outcome) fail the dispatch.
- The tap keeps a final unterminated line, never exits early, and survives the router's real ERR-trap environment.
- Executed-code mismatch on a proved application dispatch degrades, records the executed commit, writes no inventory; a development-override run never degrades on this check.
- A partial multi-package commit keeps earlier pairs valid and the manifest degraded with the last committed event ID.

### Guard, phases, provenance, migration

- Two deployments with the same configuration share one installation through separate inventories; a differing configuration is a conflict named before mutation, printing no secret material.
- Uninstall is blocked while another deployment's inventory exists, naming the deployments.
- A value declared only by another package never enters a dependency's compared set; differing such values still allow sharing.
- Failed first install leaves a valid inventory with null `applied`; retry runs install and records `applied` only after success.
- Failed reconfigure preserves `applied` bytes; `version=unknown` marks the attempt failed.
- `--adopt` records the inventory only after guarded configure succeeds; unsupported configure refuses before mutation.
- A declared version (`.version` file) lands on the result line and in the inventory; a missing or off-charset declaration yields `version=unknown` and a failed attempt; the declaration gate covers every recipe in `pkg/` (amended 2026-09-20).
- More than 64 lines, or a line over 512 bytes, fails the dispatch; the checkout line is collected once and drives the executed-code check.
- Shared teardown releases one inventory without uninstall; failed last uninstall preserves the inventory; success removes it and uninstalls when the teardown phase names the package.
- Direct uninstall over another deployment's inventory fails, naming the deployments; with `CLOUDIFY_BREAK_RELIANCES` each displaced deployment gets its own naming event and release, then the uninstall.
- A bare direct install creates an `_direct` deployment with a generated printed name and a manifest; a repeated bare install creates another; `--name` reuses that deployment; direct uninstall goes through the guard.
- Reconfigure and teardown fail on commit drift, naming both commits; a null-commit manifest fails with the unreproducible message.
- Verify and teardown seed only from successful `applied`; a failed attempt never seeds.
- Reconfigure seeding is set-scoped (ADR-030): a caller-supplied value survives reconfigure with no store entry; a store-supplied value never blocks a store edit; a deleted store entry lets the recipe default return; a set literal secret demands resupply with a digest check; `deployment unset` clears the set-mark through an event-backed transition and the next reconfigure lets the store govern the name again.
- Migration dry-run writes nothing; apply writes event first, then revision 1 under the mapped deployment directory; identical repeat is a no-op; conflicting migration fails without exposing values; external and removed records are reported, not migrated.
- No runtime caller of the old-record reader outside the migration command.

No implementation test may weaken the payload goldens or a fragile-surface pin.

## Implementation sequence

### 4.1 State and event substrate

1. Red schema fixtures and projection tests.
2. The event schema amendments: `tool_version`, non-secret `source_form` with the secret-exclusion rule, fixtures for both.
3. The flat context declaration-origin and package-instance fields under the fragile-surface gate, including the `cloudify_context_validate` accepted-shape extension.
4. Generalize the one jq schema validator; reshape the package-inventory schema; the reserved step IDs `defaults`, `init` and `direct` join runbook-step validation with fixtures.
5. The shared ID helper and writer identity.
6. Immutable event rendering and hard-link creation.
7. Inventory rendering with event-first replacement.
8. Subject-level gap detection.

No inventory writer lands before step 5 is green.

### 4.2 Immutable identity, instances, and paths

1. The ivps deliverable: immutable id per node (landed, ivps ADR-009) and instance records (`nodes/<node-id>/instances/<instance-id>/instance.json`, `ivps node path <node>:<instance>` id-keyed), adopted by cloudify, so a rename moves nothing.
2. Host origin and continuity: `cloudify/host.json` written once at first inventory write (origin `discovered|asserted|unknown` from the ivps instance record or `--baseline`; continuity = host id + boot id); every dispatch checks continuity before mutation.
3. The `.package-instance` contract and tests.
4. Instance identity from the context; per-node path helpers (`deployments/`, lock).
5. Reject external durable state; ship the README or release note on the external-host suspension, the local-inventory prerequisite, the executed-commit freshness requirement, and the clock-sync expectation.

### 4.3 Host lock, versions, and result lines

1. Freeze the lock, result-line, matching, and reconciliation tests.
2. The dispatch worker and bounded host lock; deployment matching (match, converge, create-printed); the `_direct` synthesis for bare installs (generated deployment, virtual `direct` step, manifest with the uniform commit rule).
- The version contract (amended 2026-09-20: declared `.version` file per package, initialized `1.0.0`, devs trusted and packages opaque) and result emission around package attempts, including native subjects and framework work.
4. The pass-through result stage, line validation, and executed-code check.
5. Reconciliation before ordered commits.
6. Delete the runtime registry writer; split the goldens.
7. Prove unconditional context cleanup and byte-identical payloads.

The result-line format was consented on 2026-09-15; the streamed-log chain is a documented fragile invariant and its gate runs on this slice.

### 4.4 Phase-specific resolution

(Amended 2026-09-21, Rachid's ruling, ADR-030: reconfigure seeding is set-scoped. The discriminator is provenance, not application - a value whose resolution source at apply time was the caller environment is "set". Reconfigure resolves, strongest first: caller environment > applied set values > deployment desired inputs > application defaults > package defaults > global defaults > recipe defaults. A set value outranks the store until `cloudify deployment unset` clears the mark; applied non-set values never seed - the store re-supplies them, and a deleted store entry lets the recipe default return. The applied record and its events carry each value's resolution source; a set literal secret is digest-only and demands resupply with a digest check. `cloudify deployment show` renders the applied inputs with set/store provenance. Install is unchanged - same rungs, same order, same exports; only the commit writes the provenance field.)

1. The set-scoped reconfigure ladder above; extend the context machinery to the paths that still lack it (local verify; future runbook verify and teardown dispatches).
2. Seed verify and teardown from `applied` only.
3. Matching resupply for redacted literals - superseded by ADR-031 (a second deployment requires a name; unprovable equality refuses), not built.
4. Install defaults never reinterpret an existing inventory.
5. The applied-inputs read surface (`deployment show`) and `cloudify deployment unset <id> <NAME>` as an event-backed inventory transition.

### 4.5 Guard and adoption

1. Node-scan guard checks under the host lock; starts only after the REDESIGN subject-scope qualifier alignment lands.
2. Adoption (`--adopt`) with guarded configure.

### 4.6 Teardown, override, and failure state

1. Inventory release on shared teardown.
2. The `CLOUDIFY_BREAK_RELIANCES` override with per-deployment events.
3. The commit-drift gate.
4. Preserve `applied` on failure; record degraded or unknown health through event-backed transitions.

### 4.7 Migration and phase gate

1. Consume the old registry fixtures moved in 4.3.
2. The narrow old-record reader and dry-run command.
3. Idempotent event-first apply under mapped deployment directories.
4. Focused suites, one real shared-dependency case, lint, full unit, the Phase 4 E2E scenarios.
5. Final SPEC and Technical implementation reviews before the phase commit.

## Gate conditions

This design is accepted only when:

- Rachid approves this document in plain language (revision 7 semantics accepted 2026-09-17; revision 8 amendments consented 2026-09-17; implementation-diff reviews at the phase exit carry fresh budgets per the SDLC rule);
- fresh independent SPEC and Technical reviews return `PASS` with file and line evidence on the approved revision;
- the two fragile-surface changes already flagged (the flat-context field shapes and the result-line format) hold their recorded consent, and the reconfigure ladder insert plus the `applied` source label get their own go before step 4.4;
- the next consented REDESIGN alignment carries: the subject-scope qualifier for the fail-before-mutation sentence, and the teardown release-after-recipe ordering (the version-comparison, default-name, and unknown-result amendments landed in REDESIGN with this revision);
- the REDESIGN amendment of this revision (inventory holds the package version; the application commit lives at the deployment level) is confirmed with this document.

No code is written before all of the above.
