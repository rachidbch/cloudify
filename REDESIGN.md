# Cloudify state model redesign v2

Status: accepted design, not implemented.

This design supersedes the implementation contract in ADR-021.

Concept definitions live in `GLOSSARY.md`.

Implementation lives in `plans/state-model-v2.md` and remains behind the project CRITICAL GATE.

## Decision in one breath

An application is a versioned runbook.

A deployment is one named application instance, identified by `(application, flavor, deployment name)`.

Deployment inputs record what the operator wants, package state records what Cloudify last applied successfully, and events record what happened.

Cloudify resolves a dispatch's values once and uses that same dispatch context for preflight, remote forwarding, state, and event metadata.

A physical package instance has one state record per host, with deployment claims inside it, so two deployments cannot both claim contradictory truths about one installation.

Current deployment bindings and status live in a small manifest.

Events are an audit and repair aid, not a command-replay engine or a substitute for current state.

## The proved defect

One run currently computes values twice.

The run snapshot copies only `value.*` from the deployment store.

The registry writer separately computes `var.*` from caller environment, deployment, package, and global sources.

Those results are never compared and may disagree.

The fix is one resolution per dispatch, not deleting the deployment input scope.

## Boundaries

- Plans and recipes live in git.
- Operator-authored defaults and deployment inputs live under Cloudify configuration.
- Cloudify observations, deployment manifests, runs, and events live under Cloudify state.
- Host-bound package state may live inside the ivps node directory because it must die with that node.
- ivps owns node inventory and lifecycle.
- Cloudify owns every Cloudify schema and never asks ivps to parse it.
- Each tool writes its own event directory.
- A shared event envelope may let readers merge the two streams, but neither tool writes the other's files.
- The first implementation assumes one operator machine and one local filesystem.
- Multi-operator writes and replicated inventory are deferred until they have a real coordination service.

## Identity

### Application

An application is one runnable runbook.

Its identity is two validated components: application name and flavor.

The default flavor is `default`.

The canonical reference is `<application>/<flavor>`.

The runbook lives at `runbooks/<application>/<flavor>/runbook.md`.

The application commit is the Cloudify git commit containing that runbook and its package recipes.

### Deployment

A deployment is one named instance of an application.

Its identity is the tuple `(application, flavor, deployment name)`.

The tuple is never flattened into an ambiguous path component.

Two applications may both have a deployment named `default` without collision.

A command identifies a deployment with the application reference and `--name <name>`.

The application command exports `CLOUDIFY_APPLICATION`, `CLOUDIFY_FLAVOR`, and `CLOUDIFY_DEPLOYMENT_NAME` for its child dispatches.

`CLOUDIFY_DEPLOYMENT` remains an opaque legacy ID used only by legacy commands during migration.

It cannot be translated into the tuple without an explicit application and flavor supplied to migration.

The default deployment name is `default`.

Example:

```bash
cloudify app run k3s/default --name prod
cloudify deployment show k3s/default --name prod
```

On disk, each tuple component is a separate validated directory component.

### Hosts and targets

A host remains a node, an instance on a node, or an external SSH host.

A target is a runbook slot such as `server`, `agent`, `guest`, or `gateway`.

A binding maps one target slot to one resolved host.

Bindings are current deployment state because reconfigure, verify, and teardown need them.

Changing a binding with active claims is a migration, not a normal rerun.

Until ivps has stable node and instance IDs, renaming a host with active Cloudify state is unsupported and must fail loudly where Cloudify can detect it.

Durable state for an external host requires a pinned SSH host-key fingerprint.

## Data homes

The paths below are the logical contract.

Cloudify exposes one state-root helper using `${XDG_STATE_HOME:-$HOME/.local/state}/cloudify`.

Configuration continues to use the existing Cloudify XDG configuration helper.

### Defaults and desired inputs

```text
${XDG_CONFIG_HOME:-~/.config}/cloudify/
  remote-vars.yaml
  pkgs/<package>.yaml
  apps/<application>/<flavor>/defaults.yaml
  deployments/<application>/<flavor>/<deployment>/values.yaml
```

Global, package, and application files contain defaults.

The deployment file contains explicit desired inputs for that application instance.

A deployment input is not applied state and does not claim that a command succeeded.

The deployment file replaces the ambiguous single-component deployment directory without removing the proven cross-host value scope.

### Cloudify current state

```text
${XDG_STATE_HOME:-~/.local/state}/cloudify/
  deployments/<application>/<flavor>/<deployment>/manifest.json
  runs/<run-id>.json
  events/<year-month>/<event-id>.json
  external-hosts/<host-id>/...
```

The manifest contains the deployment identity, application commit, target bindings, lifecycle status, creation time, last run ID, and last event ID.

The manifest does not duplicate package applied values.

Runs and events use schema-versioned JSON.

### Host package state

For an ivps node or instance, Cloudify state lives under the directory returned by `ivps node path <node>`.

The logical shape is:

```text
<host-state-root>/cloudify/packages/<package>/<package-instance>/state.json
```

A package instance defaults to `default`.

A recipe that genuinely supports several independent installations on one host must declare and consume an explicit package-instance key.

External-host state uses the same shape under Cloudify state, keyed by the accepted SSH host-key identity rather than the mutable SSH alias.

## Desired inputs, applied state, and history

These are separate facts.

- Desired inputs say what the operator supplied for future work.
- Applied state says what the last successful dispatch applied to one physical package instance.
- Last attempt says what Cloudify most recently tried and how it ended.
- A claim says which deployment and runbook step currently relies on that physical package instance.
- Events say what commands Cloudify observed and in which order per subject.

None replaces another.

Cloudify state is the authoritative record of Cloudify's last confirmed observation.

The live host remains authoritative about what exists now.

Verification refreshes health and detects drift.

Folding an event log is not a substitute for inspecting a live host.

## One value resolution per dispatch

A dispatch is one `(deployment, target, top-level package, package instance, phase)` operation.

Before execution, Cloudify expands the static dependency graph and builds one private dispatch context.

The context contains a separate declared-value view for the top-level package and every dependency that may execute.

The context contains:

- deployment identity
- resolved host identity and address
- application commit
- run and step IDs
- package and package-instance identity
- phase
- each declared value's source form
- each declared value's resolved runtime form
- each value's source and secret classification

The source form is a literal, an escaped literal, or a secret reference.

The resolved runtime form exists only long enough to execute the dispatch.

The context is created with mode 0600 and removed after the parent process has written the result.

Preflight, the `envsubst` allow-list, payload exports, state update, and event metadata all consume this same context.

A bare required declaration must resolve from an explicit source, while an optional or declared-default value may remain absent or use its declared default.

No registry writer, snapshot writer, or event writer walks value sources again.

### Phase-specific value sources

Install creates a missing package claim and, when needed, a missing physical package instance.

Install resolves values in this order, strongest first:

1. Step or caller environment.
2. Deployment desired inputs.
3. Application defaults.
4. Package defaults.
5. Global defaults.
6. Recipe defaults.

Reconfigure requires an active claim and an existing successful applied record.

Reconfigure resolves values in this order, strongest first:

1. Step or caller environment.
2. Deployment desired inputs.
3. Previously applied source values.
4. Application defaults.
5. Package defaults.
6. Global defaults.
7. Recipe defaults.

Verify uses the previously applied source values by default.

When an applied secret stores only redaction and a digest, verify requires the caller or deployment desired inputs to resupply the plaintext and rejects it unless the digest matches.

A verify-only override is explicit and does not rewrite applied state.

Teardown uses the previously applied source values so it removes what was actually configured.

When teardown needs a literal secret represented only by a digest, the caller or deployment desired inputs must resupply the matching plaintext or teardown fails before mutation.

Current defaults never silently change verification or teardown behavior.

An install phase encountering an existing claim is an idempotent no-op followed by verification.

It does not resolve changed defaults again.

If the caller environment or deployment desired inputs explicitly differ from applied state, install fails and directs the operator to reconfigure or upgrade.

An unclaimed physical package with compatible applied state may receive a new claim without mutation.

An unclaimed physical package with differing explicit inputs requires `--adopt`.

Adoption runs package configure when supported and adds the claim only after success.

A package without configure support must be removed or reconciled explicitly before adoption.

Changing an existing deployment is an explicit reconfigure or upgrade.

### Shared application values

A value shared by packages is one application input, not necessarily one package variable name.

The application maps its input to each package interface.

For example, one `RDP_PASSWORD` application input may map to both `CLOUDIFY_XFCE_USER_PASSWORD` and `CLOUDIFY_GUACAMOLE_RDP_PASSWORD`.

This keeps independent package APIs independent while removing duplicate operator values.

The mapping syntax is fixed and tested before existing package names change.

## Secrets

Secret classification is explicit metadata in the package or application declaration.

Name matching such as `TOKEN|KEY|PASSWORD|SECRET` remains defense in depth only.

A persisted secret should be a backend reference.

A literal secret may remain in the 0600 deployment input file under the existing local trust model, but events never copy it.

Package applied state stores a secret reference when one exists.

When a secret arrived only as a literal, package state stores redaction plus a digest and relies on deployment inputs or the caller to supply it again.

The dispatch context may contain resolved plaintext because the target process needs it.

The context never enters git, argv, normal output, a run record, or an event.

Debug output prints names, source labels, and redacted metadata, never a rendered secret-bearing payload.

The in-run `CLOUDIFY_OUTPUTS_FILE` channel remains ephemeral and mode 0600.

Step outputs are not persisted automatically in runs or events.

A value needed by a later run must be written deliberately as a deployment input, preferably as a secret reference.

A generated secret that must survive the run is deliberately stored in a deployment input or secret backend and is never persisted as an automatic step output.

## Physical package state and claims

One physical package instance has one state record on one host.

The record does not multiply because several deployments use the same installation.

The state record contains:

- `schema_version`
- subject identity
- monotonically increasing `revision`
- `applied`, containing the last successful package version, application commit, source-form values, time, and event ID
- `last_attempt`, containing phase, requested value metadata, outcome, time, and event ID
- `health`, containing the last verification result and time
- active deployment claims, keyed by deployment identity and stable runbook step ID

A failed attempt updates `last_attempt` and health but never overwrites `applied`.

A successful install or reconfigure updates `applied`.

A verify updates health but not applied values.

A claim may be added only when its requested configuration is compatible with the current physical package instance and every active claim.

Compatible means the package and package-instance identity, applied recipe commit or declared package version, and every configuration-affecting declared value match.

Non-secret values compare by source value, secret references compare by reference, and literal secrets compare by digest.

A conflicting claim fails before mutation and names the deployments in conflict.

Teardown releases every claim owned by the deployment, including dependency claims without authored uninstall steps.

The pinned teardown phase decides which unclaimed physical packages are actually uninstalled.

An unclaimed dependency remains installed unless the pinned teardown phase explicitly names it.

The package is uninstalled only when the last active claim is released and the application teardown asks for uninstall.

A force flag may override claim protection only with a destructive confirmation and an event naming every displaced claim.

Dependencies actually touched by `pkg_depends` must report their physical state and claims.

The remote result channel reports package identity, parent, instance, and outcome without carrying values.

The parent looks up that package's values in the precomputed dispatch context and never walks sources again.

A runtime dependency absent from the precomputed graph fails its state commit and marks the run degraded rather than inventing values after execution.

The router's original command-line package list is not an adequate inventory of dependency work.

## Application lifecycle and phases

The machine phase names are:

- `install`
- `reconfigure`
- `verify`
- `teardown`

Existing package operations remain `install`, `configure`, `verify`, and `uninstall`.

The runbook phase describes when a step runs.

The step type describes what the step does.

Default mappings are:

- `launch` and `install` steps default to `phase=install`.
- `configure` steps default to `phase=reconfigure`.
- `verify` steps default to `phase=verify`.
- `uninstall` steps default to `phase=teardown`.
- `run` and `human-gate` steps in canonical runbooks must declare a phase.

The `reconfigure` application phase invokes package `configure` operations.

The `teardown` application phase invokes package `uninstall` operations where the pinned runbook asks for them.

All legacy-path runbooks remain executable through the legacy engine during one compatibility period.

The legacy engine emits a deprecation warning when `run` or `human-gate` has no phase.

Every shipped runbook is migrated before it becomes eligible for canonical application execution.

A bare application run executes `install`, then `verify`.

Reconfigure and teardown are explicit commands.

Preflight checks only the phases selected for that command.

Package-level automatic verification remains intact.

The application verify phase is for cross-package, cross-host, exposure, and human acceptance checks.

Repeating a package verification explicitly is allowed but not required.

Reconfigure may rewrite configuration, restart services, rotate secrets, and update artifacts.

Reconfigure must not create or remove hosts, change package ownership, or erase persistent data unless the command explicitly requests that mutation.

Every phase must be safe to rerun after interruption.

## Deployment manifests and bindings

The manifest is created before the first mutating step.

Its initial lifecycle status is `applying`.

It records the exact target bindings used by the run.

A successful install and verify sequence changes the status to `active`.

A failed or interrupted run changes it to `degraded` or leaves enough process identity to classify it as interrupted on the next read.

Reconfigure and verify use the recorded bindings unless the caller supplies an explicit migration.

Teardown uses the recorded bindings.

A deployment with active claims cannot be silently rebound to another host.

A successful teardown removes the current manifest and desired-input directory only after every claim and application-owned external resource has been released.

Its runs and events remain history.

`cloudify deployments` lists current manifests, not historical run files.

Historical executions belong under a separate runs surface.

## Runs and events

A run record is written atomically before the first selected step.

It contains schema version, run ID, deployment identity, application commit, selected phases, start time, writer identity, and status.

The writer identity includes enough local process and boot information to identify an abandoned `running` record after a crash.

The parent process updates the run to `succeeded`, `failed`, or `interrupted` with an end time.

Manifest changes use one local per-deployment lock.

Host mutation and manifest locks are never held together.

A run record is created first, host dispatches and their package event and state commits follow, and the manifest is updated last from collected parent-process results.

A crash before the manifest update is detectable from the run and package events.

An event records an observed attempt or state transition.

Events contain:

- schema version
- unique event ID
- time
- writer and tool
- run and step IDs
- deployment identity
- subject identity
- phase and command kind
- value names, source labels, references or digests, and secret flags
- exit status and bounded non-secret summary
- previous and resulting subject revision when state changes

Events never contain raw stdout, stderr, rendered payloads, or literal secrets.

Detailed command output remains in the existing protected Cloudify log and is referenced by path and digest where useful.

Cloudify and ivps may use the same envelope version while keeping tool-specific payloads and separate writer-owned directories.

### Write protocol

Concurrency is serialized by one local host mutation `flock` and one separate local lock per deployment manifest.

The host mutation lock covers remote execution plus result commits for every top-level and dependency package touched by that dispatch.

This deliberately serializes package mutations on one host so nested dependencies need no nested locks.

No process holds a host mutation lock and a manifest lock together.

The parent process acquires the host mutation lock before remote execution and keeps it through result commits.

For each top-level or dependency package result, it performs this protocol under that host lock:

1. Read the package subject's current state and revision.
2. Build the result event and next state from the already-resolved dispatch context and remote result.
3. Atomically create the immutable event with a collision-resistant ID.
4. Atomically replace the package state with revision plus one and the event ID.

The parent then releases the host mutation lock, acquires the deployment manifest lock, updates the manifest from all collected results, and releases it.

A multi-package dispatch is not one atomic transaction.

A partial commit leaves a failed or interrupted run plus per-package events and revisions that report exactly which results were committed.

An event written before a crash but not reflected in state is unapplied audit evidence.

A state-check command reports that condition and may apply an unambiguous state transition only with an explicit repair flag.

There is no global total ordering requirement.

Ordering is per subject through revisions and per run through step IDs.

Atomic rename alone is not concurrency control.

## Teardown and code drift

The deployment manifest pins the application commit that created the active deployment shape.

Stable runbook step IDs tie claims to application steps.

Package claims decide which physical packages belong to the deployment.

The pinned runbook teardown phase decides how to release package claims and non-package resources, and in which order.

Teardown must not rely only on the current runbook because a newer runbook may have removed a step.

Reconfigure or teardown from a different application commit requires an explicit upgrade or migration decision.

Production application runs require a clean, identifiable commit.

A development override marks the deployment unreproducible and disables claims of exact teardown or replay.

Cloudify must be able to execute the pinned code before claiming safe historical teardown.

Until pinned remote execution exists, commit drift fails loudly rather than running today's recipe under yesterday's state.

## Read surface

The intended application commands are:

```bash
cloudify app run <application>[/<flavor>] [--name <name>]
cloudify app reconfigure <application>[/<flavor>] [--name <name>]
cloudify app verify <application>[/<flavor>] [--name <name>]
cloudify app teardown <application>[/<flavor>] [--name <name>]
```

The intended state commands are:

```bash
cloudify deployments
cloudify deployment show <application>[/<flavor>] [--name <name>]
cloudify --on <target> state [--application <application>[/<flavor>]] [--name <name>]
cloudify runs [--application <application>[/<flavor>]] [--name <name>]
cloudify run show <run-id>
cloudify state check
cloudify --on <target> show overlay-name
```

Direct package commands remain available and backward compatible except for claim protection.

A direct package command without deployment context has no deployment claim.

Direct uninstall blocks when any deployment claim exists.

The destructive override requires confirmation and records every displaced claim.

Legacy `cloudify deployment delete` retains old-record cleanup during compatibility but refuses to delete a v2 deployment with a manifest or active claims and directs the operator to `cloudify app teardown`.

## Compatibility and migration

The current deployment store, registry records, run snapshots, router grammar, package APIs, remote payload, and shadows remain readable until their replacements have passed parity tests.

The current registry remains observation-only and never enters the generic value ladder.

Only the v2 physical package state's last successful `applied` section may seed the explicit reconfigure, verify, and teardown phase paths.

Migration is explicit, idempotent, and rollback-safe before old files are retired.

Every new JSON artifact has `schema_version` from its first release.

A migration inventories old files before writing new ones and emits a non-secret report.

Old deployment IDs map only with an explicit application reference because the old single string does not encode application and flavor.

The legacy `CLOUDIFY_DEPLOYMENT` value remains an opaque compatibility identity until a migration command receives the missing application and flavor explicitly.

Legacy runbook files at `runbooks/<application>/<flavor>.md` remain discoverable and executable through the legacy command during one compatibility period.

Run snapshots remain the replay source until run records plus desired inputs and bindings have proven equivalent replay inputs.

Persisted `output.*` lines are not replay inputs today and are not copied into new run records.

No phase deletes old snapshots in the same release that introduces events.

Rollback restores readers to the old files without reverse-transforming newer state.

## Explicitly deferred

The following work is not part of the state-model fix:

- automatic command replay from events
- log folding as a reconstruction or drift engine
- multi-operator writes
- event replication or a broker
- immutable ivps node and instance IDs
- ivps provider and origin field normalization
- six-list address normalization
- ivps role and gateway redesign
- engine metadata redesign
- automatic host rename migration

Each may receive its own ADR when a proved need and migration path exist.

## Success criteria

The redesign is complete only when all of these are true:

- One dispatch performs one value resolution.
- The exact resolved context drives forwarding and all records.
- A first install has a durable deployment input source.
- Reconfigure uses the last successful applied state without overwriting it on failure.
- Two deployments cannot hold contradictory claims on one physical package instance.
- Teardown cannot remove a package still claimed by another deployment.
- A normal run cannot execute teardown steps.
- Current target bindings survive across runs.
- Application and deployment identities cannot collide.
- No literal secret enters an event, run record, debug payload, or persisted step output.
- Concurrent same-subject dispatches cannot lose a state transition.
- A crash between event and state writes is detectable.
- Existing direct package commands and all shadow behavior remain intact.
- Old state remains readable through the compatibility period.
- The scoped unit, integration, and disposable E2E gates pass.
