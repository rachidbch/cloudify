# Cloudify state model redesign v2

Status: accepted design, not implemented.

This design supersedes the implementation contract in ADR-021.

Concept definitions live in `GLOSSARY.md`.

Implementation lives in `plans/state-model-v2-recovery.md` through the `PLAN.md` pointer and remains behind the project fragile-surface rule (`AGENTS.md`, `docs/FRAGILE.md`).

## Decision in one breath

An application is a versioned runbook.

A deployment is one named application instance, identified by `(application, flavor, deployment name)`.

Deployment inputs record what the operator wants, package state records what Cloudify last applied successfully, and events record what happened.

Cloudify resolves a dispatch's values once and uses that same dispatch context for preflight, remote forwarding, state, and event metadata.

Deployments that rely on the same installation are guarded: one deployment cannot silently break or remove another's installation.

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

`CLOUDIFY_DEPLOYMENT` is accepted only as an opaque input to the temporary migration command; runtime commands use the tuple and never split the old ID.

It cannot be translated into the tuple without an explicit application and flavor supplied to migration.

There is no default deployment name.

A deployment id is human-set through `--name`, or generated as `<application>-<flavor>-<UTC-timestamp>` with a short suffix when needed; the same name is the same deployment (ADR-026).

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

Changing a binding while the deployment relies on installations is a migration, not a normal rerun.

A node or instance carries an immutable ivps id beside its mutable name; durable state follows the immutable id, so renaming a host does not orphan its state.

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

### Per-node deployment inventory

For an ivps node or instance, the deployment inventory lives under the directory returned by `ivps node path <node>`, in a deployment-first, human-readable tree:

```text
<host-state-root>/deployments/<application>/<flavor>/<deployment-name>/packages/<package>/<package-instance>/state.json
```

This is the cloudify inventory: the ivps inventory lists the hosts; cloudify inventories plugged into it record what cloudify configured on each (ADR-027). The `packages/` segment reserves the deployment directory for future non-package facts.

Walking a node's tree answers what runs on it.

Host origin and continuity (ADR-028): ivps and the engine can restore, recreate, or move hosts, so the inventory never claims "the machine is in this state" - it binds the machine's origin (base image fingerprint, created-at, from ivps instance records; `discovered`, `asserted`, or `unknown`) to a continuity anchor (immutable ivps host id plus last-seen boot id), and every dispatch compares the observed pair before any mutation: a replaced or rewound machine fails before mutation until verify or re-adoption.

The deployment id is the deployment name: human-set through `--name`, else generated as `<application>-<flavor>-<UTC-timestamp>` with a short suffix when needed.
The same name is the same deployment; it is chosen at first run, recorded in the manifest, and reused unchanged on every host the deployment touches.

A run with no name matches an existing deployment of the same runbook by resolved value source forms and bindings; a match converges that deployment. A run that matches nothing while deployments already exist refuses, naming them: deploying the same application twice requires naming at least one (ADR-031). A run with no name and no existing deployment creates the first one with a generated id, printed clearly.

Package instances follow the same principles: the key is `default`, or the value of a recipe-declared instance variable; the same configuration is the same installation, and a different configuration is a different installation.

### Cross-host deployment glue

A deployment spans hosts, so no single node owns it.
The minimal cross-host glue lives under Cloudify's own state root:

```text
${XDG_STATE_HOME:-~/.local/state}/cloudify/
  deployments/<application>/<flavor>/<deployment>/
    manifest.json
    runs/<utc-timestamp>.json
  events/<year-month>/<event-id>.json
  external-hosts/<host-id>/...
```

(Amended 2026-09-25, Rachid's ruling: the runbook front matter carries no deployment or run id. A run needs no operator-chosen key: the deployment is assembled at run time - application and flavor from the runbook path, name from `--name`, hosts from `--target` - and a run identifies itself by its UTC timestamp under that deployment. Run history lives in the state tree, never in the flat configuration store; the exact runs placement is settled by the run-store cleanup slice, which also removes the legacy `deployments/<id>/runs` folders and the dotted-id lookup workaround.)

(Runs placement settled 2026-09-27, Rachid's ruling: per-deployment. A run lives at `deployments/<application>/<flavor>/<deployment>/runs/<utc-timestamp>.json` - walking one deployment directory tells its whole story, the run key derives from identity (deployment path plus timestamp, no second id namespace), and `deployment delete` removes the story wholesale. Events stay at the root as the global audit; runs answer what the controller executed for a deployment, never what runs where - that is the ivps-tree inventory's question.)

The manifest contains the deployment identity, application commit, target bindings, lifecycle status, creation time, last run ID, and last event ID.

The manifest does not duplicate package applied values.

Runs and events use schema-versioned JSON.

## Desired inputs, applied state, and history

These are separate facts.

- Desired inputs say what the operator supplied for future work.
- Applied state says what the last successful dispatch applied to one physical package instance.
- Last attempt says what Cloudify most recently tried and how it ended.
- A reliance record says which deployment and runbook step currently uses an installation.
- Events say what commands Cloudify observed and in which order per subject.

None replaces another.

Cloudify state is the authoritative record of Cloudify's last confirmed observation.

The live host remains authoritative about what exists now.

Verification refreshes health and detects drift.

Folding an event log is not a substitute for inspecting a live host.

## One value resolution per dispatch

A dispatch is one target's job. It carries one or more top-level packages and never spans two targets.
One dispatch context therefore holds the resolved values for every package the dispatch carries - the top-level packages and the dependencies they pull in - in one namespace.

Resolution happens once and the context is written once, after resolution completes.
A context written incrementally while resolution is still running is the last-writer-wins defect and is forbidden: later sources would overwrite earlier ones and the recorded source would drift from the value.

Precedence is first source wins. The first source to provide a name claims it and records where it came from; every later source is refused without looking.
The visit order is not the precedence order: the caller's environment is visited last yet wins, because a source refuses to overwrite a name that is already set.

Records and events use a value's source form. Only the payload uses the resolved runtime form.

Before execution, Cloudify expands the static dependency graph and builds one private dispatch context.

Values are dispatch-global: every top-level package and every dependency that may execute resolves into one namespace, and the first source to provide a name keeps it for the whole dispatch.
The named package is resolved before the packages it pulls in, so its value wins over theirs - which is how one package configures another. A package that needs a variable no other package shares prefixes the name with the package name in upper case.

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

Each declared value carries: its declaration kind, its source label, its source form, its **raw source form**, its resolved runtime form, and its secret classification.

The raw source form is the exact text the registry record and the run snapshot must contain. It is why no consumer reopens a source: whoever resolves a value records its raw text at the same moment, so the recorded text cannot drift from the forwarded value, and an absent value stays distinguishable from a present-but-empty one.
A raw form that cannot be carried on one line is transported in an explicit, unambiguous encoding, so a raw text that itself looks encoded is never mistaken for the transport.

A value's raw form and its resolved runtime form both live in the context, and the context is removed when the dispatch ends. That removal is what bounds the resolved runtime form; it may never appear in a log, a manifest, package state, a run record or an event. The raw source form is by design the text the registry record and the run snapshot store, so those two are where it belongs - and nowhere else.

The context is validated before payload construction and before any mutation. A malformed or partial context fails loudly, because a silently empty context stops payload forwarding without an error.

The resolved runtime form exists only long enough to execute the dispatch.

The context is created with mode 0600 and removed after the parent process has written the result.

The parent process owns the context path. It creates the context, forks one dispatch job per target, waits for them, and writes each result. The child job fills the context, renders the payload and ships it.
The context is a file because it is the only channel from the child back to the parent: a fork inherits downward only.

Preflight, the `envsubst` allow-list, payload exports, state update, and event metadata all consume this same context.

A bare required declaration must resolve from an explicit source, while an optional or declared-default value may remain absent or use its declared default.

No registry writer, snapshot writer, or event writer walks value sources again.

### Phase-specific value sources

Install starts a reliance and, when needed, creates the missing package instance.

Install resolves values in this order, strongest first:

1. Step or caller environment.
2. Deployment desired inputs.
3. Application defaults.
4. Package defaults.
5. Global defaults.
6. Recipe defaults.

The recipe default is the recipe's own shell fallback on the host (`${NAME:-default}` in the recipe code): cloudify never exports the `.remote-vars` mirror text, so a declared-but-unsupplied name is absent from the dispatch context and the recipe's fallback applies on the host (ADR-029).

Reconfigure requires an existing reliance and a successful applied record.

Reconfigure resolves values in this order, strongest first:

1. Step or caller environment.
2. Previously applied values that were set (caller-sourced at apply time; ADR-030).
3. Deployment desired inputs.
4. Application defaults.
5. Package defaults.
6. Global defaults.
7. Recipe defaults.

A set value outranks the store until it is explicitly unset (`cloudify deployment unset`): a value the operator supplied directly never moves because a default under it shifted.
Applied values that were store-supplied never seed: the store re-supplies them when present, and a deleted store entry lets the recipe default return - the deletion is honored, not buffered.

The applied record carries each value's resolution source, and `cloudify deployment show` renders the applied inputs with their set/store provenance, secrets masked to reference or digest.

Verify uses the previously applied source values by default.

When an applied secret stores only redaction and a digest, verify requires the caller or deployment desired inputs to resupply the plaintext and rejects it unless the digest matches.

A verify-only override is explicit and does not rewrite applied state.

Teardown uses the previously applied source values so it removes what was actually configured.

When teardown needs a literal secret represented only by a digest, the caller or deployment desired inputs must resupply the matching plaintext or teardown fails before mutation.

Current defaults never silently change verification or teardown behavior.

Re-running install converges: an existing reliance means the recipe no-ops when the installation already exists, and verification runs.

It does not resolve changed defaults again.

If the caller environment or deployment desired inputs explicitly differ from applied state, install fails and directs the operator to reconfigure or upgrade.

Install is the converge: recipes are idempotent, so re-running install on the same installation is safe.

Adoption is operator-asserted: `--adopt` on an install takes over an installation cloudify has no inventory for - it requires configure support, runs configure, and records the inventory only after success.

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

## Deployment inventory and the shared-installation guard

Each deployment records what it did on a node in its own directory under that node's tree, human-readable, one directory per deployment per node.

The deployment inventory contains, per package the deployment covers:

- the package and package-instance identity;
- `applied`, the last successful result: package version (required - every package reports its installed version), source-form values, and time;
- the last attempt: phase, requested value metadata, outcome, and time;
- health: the last verification result;
- the runbook step that owns the work;
- a monotonically increasing revision, changed only together with an event.

A failed attempt updates the last attempt and health but never overwrites `applied`.

A successful install or reconfigure updates `applied`.

A verify updates health but not applied values.

The node's deployment inventories show which deployments rely on an installation: the guard scans them, so two deployments relying on one installation cannot silently break or remove each other's.

A deployment may start relying on an installation only when its requested configuration is compatible with what the installation holds and with every deployment already relying on it.

Compatible means the package and package-instance identity and every configuration-affecting declared value match; the recorded version is informational and is not compared (ADR-026).

A package's configuration-affecting declared values are the values it declares itself; a value declared only by another package in the dispatch is recorded by that package's own inventory (ADR-025).

Non-secret values compare by source value, secret references compare by reference, and literal secrets compare by digest.

A conflict fails before mutation and names the deployments in conflict.

Teardown releases every reliance owned by the deployment, including dependency work without authored uninstall steps.

The pinned teardown phase decides which installations are actually uninstalled.

An installation nobody relies on remains installed unless the pinned teardown phase explicitly names it.

The package is uninstalled only when nothing relies on it anymore and the application teardown asks for uninstall.

A force flag may override the guard only with a destructive confirmation and an event naming every displaced reliance.

Dependencies actually touched by `pkg_depends` must report their state and their reliances.

The remote result channel reports package identity, parent, instance, and outcome without carrying values.

The parent looks up that package's values in the precomputed dispatch context and never walks sources again.

A runtime dependency absent from the precomputed graph fails its state commit and marks the run degraded rather than inventing values after execution.

A result naming a package the graph does not know is a graph error: the dispatch fails in full before any inventory write (ADR-026).

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

Only canonical `runbooks/<application>/<flavor>/runbook.md` files are discoverable.

Every shipped runbook is canonical and `run` or `human-gate` always declares a phase.

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

A deployment that relies on installations cannot be silently rebound to other hosts.

A successful teardown removes the current manifest and desired-input directory only after every reliance and application-owned external resource has been released.

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
- the source form of every non-secret value; secrets never carry a source form (ADR-027)
- the writing cloudify tool version
- exit status and bounded non-secret summary
- previous and resulting subject revision when state changes

Events never contain raw stdout, stderr, rendered payloads, or literal secrets.
With non-secret source forms recorded, the inventory is derivable from the event log; reproduction of historical values rests on these forms, never on the availability of a git commit - the commit pins provenance only (ADR-027).

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

Stable runbook step IDs tie reliances to application steps.

Package reliances decide which installations belong to the deployment.

The pinned runbook teardown phase decides how to release reliances and non-package resources, and in which order.

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
cloudify --on <target host> state [--application <application>[/<flavor>]] [--name <name>]
cloudify runs [--application <application>[/<flavor>]] [--name <name>]
cloudify run show <run-id>
cloudify state check
cloudify --on <target host> show overlay-name
```

Direct package commands remain available with stable signatures and stop being out-of-band: a bare install with no `--name` synthesizes a deployment under the reserved `_direct` application namespace, with a generated name, a virtual one-step runbook (stable step ID `direct`), and a manifest under the uniform commit rule (ADR-027).
Direct deployments are ordinary deployments: full inventory and events, guard, reliance, teardown.

A direct package command without deployment context has no deployment reliance.

Direct uninstall blocks while any deployment relies on the installation.

The destructive override requires confirmation and records every displaced reliance.

`cloudify deployment delete` does not exist in v2; application teardown owns reliance release and removal.

## Migration and removal

Cloudify runtime reads and writes v2 paths and schemas only.

Temporary one-shot migration commands are the sole readers of old desired-input files, registry records and snapshots.

Each migration is explicit, dry-run first, idempotent and emits names and paths without values.

Old deployment IDs map only with an explicit application reference because the old string does not encode application and flavor.

Migration preserves only facts the old artifact proves and never fabricates application commit, host identity or success.

Every new JSON artifact carries `schema_version` from its first write and validates before atomic replacement.

The current registry remains observation-only and never enters the generic value ladder.

Only the v2 physical package state's last successful `applied` section may seed reconfigure, verify and teardown.

Persisted `output.*` lines are never migrated into run records or events.

After the migration inventory reports zero old artifacts, the migration commands, old readers, old snapshot replay and migration fixtures are deleted.

Rollback is a Git revert plus restoration from a pre-migration backup, never a permanent runtime switch or dual reader.

## Explicitly deferred

The following work is not part of the state-model fix:

- automatic command replay from events
- log folding as a reconstruction or drift engine
- multi-operator writes
- event replication or a broker
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
- Two deployments cannot silently break or remove each other's installations.
- Teardown cannot remove an installation another deployment still relies on.
- A normal run cannot execute teardown steps.
- Current target bindings survive across runs.
- Application and deployment identities cannot collide.
- No literal secret enters an event, run record, debug payload, or persisted step output.
- Concurrent same-subject dispatches cannot lose a state transition.
- A crash between event and state writes is detectable.
- Existing direct package commands and all shadow behavior remain intact.
- Every old artifact is migrated explicitly or reported, and final runtime code contains no migration bridge or old-format reader.
- The scoped unit, integration, and disposable E2E gates pass.
