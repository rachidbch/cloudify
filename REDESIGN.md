# Cloudify state model redesign v2

Status: accepted design; convergence implementation is in progress through PLAN.md.

This design supersedes the implementation contract in ADR-021.

Concept definitions live in `GLOSSARY.md`.

Approved convergence work lives in `plans/state-convergence.md` through the `PLAN.md` pointer, on feature branch `feat/state-convergence`; prior recovery work is archived under `plans/archived/`.
Implementation remains behind the project fragile-surface rule (`AGENTS.md`, `docs/FRAGILE.md`).

## Decision in one breath

An application is a versioned runbook.

A deployment is one named application instance, identified by `(application, flavor, deployment name)`.

Defaults and the caller environment record what the operator wants (files hold defaults, the environment supplies values; Defaults ladder, ADR-038), package state records what Cloudify last applied successfully, and events record what happened.

Cloudify resolves a dispatch's values once and uses that same dispatch context for preflight, remote forwarding, state, and event metadata.

Deployments that rely on the same installation are guarded: one deployment cannot silently break or remove another's installation.

Current deployment bindings and status live in a small manifest.

Events are an audit and repair aid, not a command-replay engine or a substitute for current state.

## The proved defect

One run currently computes values twice.

The run snapshot copies only `value.*` from the deployment store.

The registry writer separately computes `var.*` from caller environment, deployment, package, and global sources.

Those results are never compared and may disagree.

The fix is one resolution per dispatch.

## Boundaries

- Plans and recipes live in git.
- Operator-authored defaults live under Cloudify configuration.
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
The target name belongs in the inventory record; host identity comes from its inventory location and parent identity records (Inventory owns current state, ADR-036).

Changing a binding while the deployment relies on installations is a migration, not a normal rerun.

A node or instance carries an immutable ivps id beside its mutable name; durable state follows the immutable id, so renaming a host does not orphan its state.

Durable state for an external host requires a pinned SSH host-key fingerprint.

## Data homes

The paths below are the logical contract.

Cloudify exposes one state-root helper using `${XDG_STATE_HOME:-$HOME/.local/state}/cloudify`.

Configuration continues to use the existing Cloudify XDG configuration helper.

### Defaults

```text
${XDG_CONFIG_HOME:-~/.config}/cloudify/
  remote-vars.yaml
  pkgs/<package>.yaml
  apps/<application>/defaults.yaml
  apps/<application>/<flavor>/defaults.yaml
```

Every file rung holds defaults, weakest to strongest: recipe default < global < package < application < application-flavor. The environment supplies values for one invocation and beats every standing default.

There is no per-deployment values file and no stored desired inputs (Defaults ladder, ADR-038). First installs are fed by the environment or defaults files; persistence across invocations comes from applied values recorded in inventory, marked user-forced where the environment supplied them.

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

A run with no name matches a proven-identical deployment of the same runbook by bindings, non-secret scalars, and secret-name markers; a unique match converges that deployment.
If deployments exist but no unique match is proved, refuse and name the candidates (ADR-031).
With no existing deployment, generate the first name and print it clearly.

Package instances follow the same principles: the key is `default`, or the value of a recipe-declared instance variable; the same configuration is the same installation, and a different configuration is a different installation.

### Cross-host deployment glue

A deployment spans hosts, so no single node owns it.
The minimal cross-host glue lives under Cloudify's own state root:

```text
${XDG_STATE_HOME:-~/.local/state}/cloudify/
  deployments/<application>/<flavor>/<deployment>/
    manifest.json
    runs/<utc-timestamp>.yaml
  events/<year-month>/<event-id>.json
  external-hosts/<host-id>/...
  .event-seq
```

(`.event-seq` is the event-id counter's private scratch - one flock-guarded
line `<second> <random-half> <count>`; it makes ids strictly increasing
within a writer's second so the log's path order recovers write order. Never
a record; safe to delete while idle.)

(Amended 2026-09-25, Rachid's ruling: the runbook front matter carries no deployment or run id. A run needs no operator-chosen key: the deployment is assembled at run time - application and flavor from the runbook path, name from `--name`, hosts from `--target` - and a run identifies itself by its UTC timestamp under that deployment. Run history lives in the state tree, never in the flat configuration store; the exact runs placement is settled by the run-store cleanup slice, which also removes the legacy `deployments/<id>/runs` folders and the dotted-id lookup workaround.)

(Runs placement settled 2026-09-27, Rachid's ruling: per-deployment. A run lives at `deployments/<application>/<flavor>/<deployment>/runs/<utc-timestamp>.yaml` - walking one deployment directory tells its whole story, the run key derives from identity (deployment path plus timestamp, no second id namespace), and `deployment delete` removes the story wholesale. Events stay at the root as the global audit; runs answer what the controller executed for a deployment, never what runs where - that is the ivps-tree inventory's question.)

(Run snapshot extension amended 2026-09-30, Rachid's ruling: `.yaml` - the snapshot is the replay-seed YAML and the extension tells the truth about the bytes. Any structured run record owns its own format decision when it lands.)

The manifest contains the deployment identity, application commit, target bindings, lifecycle status, creation time, last run ID, and last event ID.

The manifest does not duplicate package applied values.

Events use schema-versioned JSON; run snapshots remain replay-seed YAML.

## Defaults, applied state, and history

These are separate facts.

- Defaults files supply standing preferences; the environment supplies values for one invocation.
- Applied state says what the last successful dispatch applied to one physical package instance, including which values the environment forced.
- The failure marker says an operation failed without replacing previously confirmed settings.
- A reliance record says which deployment and runbook step currently uses an installation.
- Events say what commands Cloudify observed and in which order per subject.

None replaces another.

Cloudify state is the authoritative record of Cloudify's last confirmed observation.

The live host remains authoritative about what exists now.

Verification refreshes health and detects drift.

Verification compares a deployment against its own recorded values and never against defaults (verification ownership and provenance, ADR-046); without a record an unnamed dispatch is a liveness observation carrying its own word, never a convergence verdict.

Cloudify verifies only facts about its own actions and relays the verdicts recipes and runbooks report; package behavior - sockets, units, config files, whether live configuration matches the record - is the recipe's or the runbook's own verification.

Folding an event log is not a substitute for inspecting a live host.

## One value resolution per dispatch

A dispatch is one target's job. It carries one or more top-level packages and never spans two targets.
One dispatch context therefore holds the resolved values for every package the dispatch carries - the top-level packages and the dependencies they pull in - in one namespace.

Resolution happens once and the context is written once, after resolution completes.
A context written incrementally while resolution is still running is the last-writer-wins defect and is forbidden: later sources would overwrite earlier ones and the recorded source would drift from the value.

Precedence is first source wins. The first source to provide a name claims it and records where it came from; every later source is refused without looking.
The visit order is not the precedence order: the caller's environment is visited last yet wins, because a source refuses to overwrite a name that is already set.

Records and events retain ordinary values; classified secrets retain names only (Secrets enter through the environment, ADR-037).
Only the private execution context and payload carry supplied secret values.

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

A non-secret source form is a literal or an escaped literal.
Secret runtime values come from the caller environment; only their names survive in records (Secrets enter through the environment, ADR-037).

Each declared value carries: its declaration kind, its source label, its source form, its **raw source form**, its resolved runtime form, and its secret classification.

For non-secret values, the raw source form is the text a record may retain.
Secret values are excluded from records and future safe snapshots even when supplied as literals (Secrets enter through the environment, ADR-037).
The single resolution still prevents consumers from reopening sources and disagreeing about what executed.
A raw form that cannot be carried on one line is transported in an explicit, unambiguous encoding, so a raw text that itself looks encoded is never mistaken for the transport.

A value's raw and runtime forms may live in the private context, which is removed when the dispatch ends.
Secret plaintext must not enter a log, manifest, package record, run snapshot, or event.
Record only its name; do not persist a literal, digest, or provider address (Secrets enter through the environment, ADR-037).

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
2. Application-flavor defaults.
3. Application defaults.
4. Package defaults.
5. Global defaults.
6. Recipe defaults.

The recipe default is the recipe's own shell fallback on the host (`${NAME:-default}` in the recipe code): cloudify never exports the `.remote-vars` mirror text, so a declared-but-unsupplied name is absent from the dispatch context and the recipe's fallback applies on the host (ADR-029).

Reconfigure requires an existing reliance and a successful applied record.

Reconfigure resolves values in this order, strongest first:

1. Step or caller environment.
2. Previously applied values carrying the user-forced bit (the environment supplied them at apply time; Defaults ladder, ADR-038, simplifying ADR-030's source labels to this one bit).
3. Application-flavor defaults.
4. Application defaults.
5. Package defaults.
6. Global defaults.
7. Recipe defaults.

A user-forced value outranks every default until explicitly unset (`cloudify deployment unset` removes the bit): a value the operator supplied directly never moves because a default shifted.
Non-forced applied values never seed: their default re-supplies them each reconfigure, and a deleted default entry lets the next wider default or the recipe default return - the deletion is honored, not buffered.

The applied record carries one user-forced bit per value (Defaults ladder, ADR-038) in the lean record shape (root scalars; `****` for secret names; a root `user_forced` array; `failed: true`; version; revision; target).
`failed` is set by any failed operation and cleared only by a successful install or reconfigure; a passing read-only verify never clears it.
Secret values are represented by their names only under Secrets enter through the environment (ADR-037).

Verify uses the previously applied source values by default.

Under the environment-only secret boundary (Secrets enter through the environment, ADR-037), verify obtains required secret values from the current caller environment after application mappings.
Inventory records secret names, not values, digests, or provider locations; no historical-secret digest check is implied.

A verify-only override is explicit and does not rewrite applied state.

Teardown uses the previously applied source values so it removes what was actually configured.

Teardown takes any secret values from the caller's environment after application mappings.
Cloudify never demands or preflights secrets; a hook failing for a missing variable names the original input through the mapping, or the package variable for a bare dispatch.

Current defaults never silently change verification or teardown behavior.

Re-running install converges: an existing reliance means the recipe no-ops when the installation already exists, and verification runs.

It does not resolve changed defaults again.

If the caller environment or a defaults file explicitly differs from applied state, install fails and directs the operator to reconfigure or upgrade.

Install is the converge: recipes are idempotent, so re-running install on the same installation is safe.

Adoption is operator-asserted (ruled 2026-09-29, GLOSSARY `deployment adoption`): `cloudify adoption record <app>/<flavor>/<name> --on <target>` records the operator's inference in mechanical shape - one adoption event per package (writer: operator, no commit), the package records beside it, the manifest derived to `adopted` - then fires the seeded read-only verify whose pass ends `verified` and whose failure leaves the adoption standing. The earlier install-time `--adopt` shape (configure-gated takeover) is superseded by this command; adoption never runs a write.

Changing an existing deployment is an explicit reconfigure or upgrade.

### Shared application values

A value shared by packages is one application input, not necessarily one package variable name.

The application maps its input to each package interface.

For example, one `RDP_PASSWORD` application input may map to both `CLOUDIFY_XFCE_USER_PASSWORD` and `CLOUDIFY_GUACAMOLE_RDP_PASSWORD`.

This keeps independent package APIs independent while removing duplicate operator values.

The mapping syntax is fixed and tested before existing package names change.

## Secrets

Secret classification uses explicit markers plus an anchored suffix safety net (Secret markers with suffixes, ADR-042, superseding ADR-039's marker-only clauses). An explicit marker outranks a suffix origin on the same name, and a suffix-only classification keeps the v1 `declaration: heuristic` value; full removal of name-based recognition stays deferred to the roadmap.
A name is secret when marked with `secret NAME`, or when it ends exactly with `_PASSWORD`, `_SECRET`, `_TOKEN`, `_KEY`, or `_PWD` (case-sensitive, including the underscore).
Substring matches and bare names do not qualify; explicit markers cover exceptions such as `CLOUDIFY_ZITADEL_MASTERKEY`.
The implementation sweep still marks every shipped secret declaration and runbook input.
A runbook mapping is secret when either side qualifies; that classification follows a shared input through all its aliases, so fan-out cannot expose the same secret under an ordinary-looking name.
Complete removal of name-based recognition is deferred to the roadmap, requiring a later decision.
Runbook `inputs:` marker spelling (settled): `secret NAME` entries in the same list; the sweep adds them.

For the MVP, secret values come from the caller's environment; secretspec or another external supplier may populate it (Secrets enter through the environment, ADR-037).

Cloudify does not select a secret manager, resolve a provider address, or write a secret store.

Normal inventory and future safe snapshots retain secret names only, not values, digests, or provider locations.

Replay takes required secret values from the current invocation after application mappings and must not overwrite them with historical snapshot literals.

The external secretspec convention is one profile per named deployment; Cloudify neither derives nor validates that profile.

These rules are settled: marker-plus-suffix classification (ADR-042), no secret-demand preflight, root ordinary scalars, and operator-owned sharing of secret-bearing installations.

The dispatch context may contain resolved plaintext because the target process needs it.

The context never enters git, argv, normal output, a run record, or an event.

Debug output prints names, source labels, and redacted metadata, never a rendered secret-bearing payload.

The in-run `CLOUDIFY_OUTPUTS_FILE` channel remains ephemeral and mode 0600.

Step outputs are not persisted automatically in runs or events.

A non-secret value needed by a later run comes from a defaults-file entry or the environment (Defaults ladder, ADR-038).

A secret needed by a later run must be supplied again through its environment, usually by the external wrapper.

Generation and storage belong to that external supplier for the MVP; guest-generated secret handling is deferred and is never an automatic persisted step output.

## Deployment inventory and the shared-installation guard

Each deployment records what it did on a node in its own directory under that node's tree, human-readable, one directory per deployment per node.

The approved lean package record holds applied values as root scalars, with native JSON strings for multiline settings.
Classified secret names hold `****`, never secret values, digests, provider locations, or `redacted` flags.
Root metadata comprises `schema_version`, `target`, `user_forced`, optional `failed: true`, `version`, and `revision`.
Evolve the version-1 schemas in place with `schema_version: 1`, explicit old-record conversion, and coordinated reader/writer cutover (Schema v1 evolution, ADR-040).
Derive package, instance, deployment, and host identities from the inventory path and parent identity records rather than duplicating them.
`target` records the runbook slot; an `_direct` record uses `direct`.
`user_forced` lists names supplied by the environment when successfully applied.
Every package reports its installed version, and revision increases under the host lock together with an event.
There is no `applied` wrapper, detailed `last_attempt`, health object, or per-value source metadata.

A failed operation preserves confirmed settings and sets `failed: true`, including a first failure with no applied settings.
A successful install or reconfigure replaces confirmed settings and clears the failure marker.
A passing verify changes neither applied values nor an existing failure marker.

The node's deployment inventories show which deployments rely on an installation: the guard scans them, so two deployments relying on one installation cannot silently break or remove each other's.

A deployment may start relying on an installation only when its requested configuration is compatible with what the installation holds and with every deployment already relying on it.

Compatible means the package and package-instance identity and every configuration-affecting declared value match; the recorded version is informational and is not compared (ADR-026).

A package's configuration-affecting declared values are the values it declares itself; a value declared only by another package in the dispatch is recorded by that package's own inventory (ADR-025).

Non-secret values compare by their recorded values.

Secret values are never compared (Secrets enter through the environment, ADR-037): the operator knows how each package reacts to its environment and owns sharing decisions for secret-bearing installations.
The guard compares non-secret recorded values only; two `****` entries are unrelated facts, never conflicting or matching credentials.

A conflict fails before mutation and names the deployments in conflict.

Teardown releases every reliance owned by the deployment, including dependency work without authored uninstall steps.

The pinned teardown phase decides which installations are actually uninstalled.

An installation nobody relies on remains installed unless the pinned teardown phase explicitly names it.

The package is uninstalled only when nothing relies on it anymore and the application teardown asks for uninstall.

A force flag may override the guard only with a destructive confirmation and an event naming every displaced reliance.

Dependencies actually touched by `pkg_depends` must report their state and their reliances.

The remote result channel reports package identity, parent, instance, and outcome without carrying values.

The parent looks up that package's values in the precomputed dispatch context and never walks sources again.

A runtime dependency absent from the precomputed graph fails its state commit and marks the run failed rather than inventing values after execution.

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

The manifest is a read cache of current deployment facts held in the ivps inventory (Inventory owns current state, ADR-036).
Use it when valid and current; recreate it from inventory when missing, corrupt, or stale.
Inventory must retain each target-to-host association and every other fact required to reconstruct current state.
Local events and runs may speed inspection or answer history questions, but are not required for current-state recovery or continuation.
Adoption pins no application commit that no dispatch proved.
The current event-dependent rebuild and inventory checks are compliance bugs to fix after specification convergence, not alternative authorities.

The manifest is created before the first mutating step.

Local observation words are `adopted`, `installed`, `reconfigured`, `verified`, and `failed` (Defaults ladder, ADR-038).
Any failed operation sets `failed`; a passing verify cannot clear the inventory failure marker (Marker-only classification, ADR-039).
A rebuilt manifest derives `failed` when a failure marker exists, otherwise `installed` when applied settings exist, otherwise no word (Inventory owns current state, ADR-036).
Adopted deployments rebuild to `installed`.
Rebuild on read when the cache is missing or corrupt, or any package revision exceeds its cached high-water mark; keep explicit rebuild.

It records the exact target bindings used by the run.

Reconfigure and verify use the recorded bindings unless the caller supplies an explicit migration.

Teardown uses the recorded bindings.

A deployment that relies on installations cannot be silently rebound to other hosts.

A successful teardown removes the current manifest only after every reliance and application-owned external resource has been released.

Its runs and events remain history.

`cloudify deployments` lists current manifests, not historical run files.

Historical executions belong under a separate runs surface.

## Runs and events

`cloudify deployment replay` without `--at` converges current state from inventory, never the newest snapshot.
`--at <run>` restores that YAML snapshot's ordinary settings.
Both paths take secrets only from the new invocation's environment after names-only mappings; snapshot literals and inventory markers never overwrite them.

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
- ordinary recorded settings and secret-name markers `****`; secret values, digests, and provider locations are excluded (Secrets enter through the environment, ADR-037)
- the recorded form of every non-secret value; secret names are retained without their values
- the writing cloudify tool version
- exit status and bounded non-secret summary
- previous and resulting subject revision when state changes

Events never contain raw stdout, stderr, rendered payloads, or literal secrets.
Events retain ordinary settings for audit and explicit historical repair; current inventory recovery and continuation never require them (Inventory owns current state, ADR-036).

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
4. Atomically replace the package state with revision plus one; the event records the previous and resulting revisions.

The parent then releases the host mutation lock, acquires the deployment manifest lock, updates the manifest from all collected results, and releases it.

A multi-package dispatch is not one atomic transaction.

A partial commit leaves a failed or interrupted run plus per-package events and revisions that report exactly which results were committed.

An event written before a crash but not reflected in state is unapplied audit evidence.

A state-check command reports that condition and may apply an unambiguous state transition only with an explicit repair flag.

There is no global total ordering requirement.

Ordering is per subject through revisions and per run through step IDs.

Atomic rename alone is not concurrency control.

## Teardown and code drift

A dispatch event records the application commit that produced the deployment shape it wrote; the manifest caches the latest such commit. Deployment adoption pins no commit - no dispatch proved one.

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

Direct package commands remain available with stable signatures and stop being out-of-band: a bare install synthesizes a deployment under the reserved `_direct` application namespace, named by allocation (an explicit `--name`, else the invocation's first package word with a numbered suffix, allocated under the host lock), with a virtual one-step runbook (stable step ID `direct`) and a manifest under the uniform commit rule (ADR-027; direct naming and resolution, ADR-045).
Direct deployments are ordinary deployments: full inventory and events, guard, reliance, teardown.
Direct state is state, not an observation bucket (direct state with a mechanical lifecycle, ADR-044): it exists while its payload is deployed; a successful teardown deletes the package's record mechanically in the worker, and the deployment's manifest once no records or bindings remain; its recorded applied values seed later dispatches, with the caller environment still winning on the defaults ladder; a nameless verify that resolves to direct state records under it, while with no resolved state it stays an ad-hoc observation and records nothing. A nameless command resolves by candidates - deployments holding a record for that package on that host: one candidate with equal resolved values proceeds silently, otherwise the candidates are named and the command stops, and forcing proceeds on the single-candidate case as a reconfigure. Values never participate in a name, so a reconfigure keeps its identity while two installations that differ in a non-secret value are distinct states, including in parallel.
Retention sweeps are a debris backstop, never the lifecycle; a liveness sweep may delete only debris and never a named deployment's records because a host dropped out of the live inventory.

A direct package command without deployment context has no deployment reliance.

Direct uninstall blocks while any deployment relies on the installation.

The destructive override requires confirmation and records every displaced reliance.

`cloudify deployment delete` does not exist in v2; application teardown owns reliance release and removal.

## Migration and removal

Cloudify runtime reads and writes v2 paths and schemas only.

Temporary one-shot migration commands are the sole readers of old desired-input files, registry records and snapshots.

Each migration is explicit, idempotent and emits names and paths without values; live conversion proceeds one application at a time with per-write backups and rollback (per-application live conversion, ADR-043).

Old deployment IDs map only with an explicit application reference because the old string does not encode application and flavor.

Migration preserves only facts the old artifact proves and never fabricates application commit, host identity or success.

Every new JSON artifact carries `schema_version` from its first write and validates before atomic replacement.

The current registry remains observation-only and never enters the generic value ladder.

Only confirmed inventory settings may seed addressed deployments: reconfigure uses user-forced ordinary values, while verify and teardown use recorded ordinary settings.
Secrets always come from the new invocation's environment after mappings.

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
- A first install can be fed from the environment or defaults files; durable current state lives in inventory (Defaults ladder, ADR-038).
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

The Guacamole canary runs its seven real lifecycle checks inside the dedicated cloudify test host through one Tailscale SSH session (Dedicated-host canary, ADR-041).
It does not prove remote dispatch or inventory recording; transport, state, and batch-exit remote E2E tests cover those claims separately.

## Environment-only secrets for the MVP (ADR-037; approved implementation queued)

Secretspec stays outside Cloudify and supplies environment variables through its normal wrapper.
Cloudify may receive the same variables from another caller; it has no secretspec dependency or provider allowlist.
The wrapper chooses the spec, profile, provider, and any generation or prompting.
One secretspec profile per named deployment remains the external setup convention, not a Cloudify selection algorithm.

Before mutation, Cloudify applies the runbook's names-only mappings and records which environment names are secrets - the `****` entries in inventory.
It never demands or preflights secrets.
When a recipe or verify hook fails because an environment variable is missing, the failure names that variable and points at the external supplier; the runbook's `inputs:`/`map:` (or, for a bare dispatch, the variable name) tells it which name that is.
On replay from current inventory, the record's `****` entries are how Cloudify knows which names are secret; the runbook `map:` says which input name feeds them.
Cloudify records the secret names but not their values, digests, project/profile/provider addresses, or mode/key selectors.
A safe replay preserves ordinary recorded settings and takes secrets from the new invocation's environment, after mappings.
It never restores a historical secret literal or calls a secret backend.

This removes the earlier capture modes, `store`/`fetch` interface, new policy file, file-only provider restriction, and provider-aware snapshot design from the MVP.
The older Secret capture decision (ADR-034) remains history, superseded by Secrets enter through the environment (ADR-037).
Optional secretspec-aware UX is future work, not a prerequisite of deployment or replay.

The specification gaps named when this section landed are settled (2026-10-17):

- classification: explicit `secret NAME` markers plus the exact suffix list in Secret markers with suffixes (ADR-042); substring matching is retired, and complete removal of name-based recognition is deferred;
- demands: none - a recipe or verify hook failing for a missing secret fails loudly and names it (graceful, Secrets enter through the environment, ADR-037);
- record: root scalars, `****` names, root `user_forced` array, `failed: true`, version, revision, target;
- provenance: the user-forced bit replaces the earlier set/store labels (Defaults ladder, ADR-038);
- sharing: the operator owns secret-bearing installation sharing; the guard compares only declared non-secret values and never compares `****` entries;
- input identity: replay failure reporting derives the missing-variable names from the runbook's `inputs:`/`map:` (bare dispatches: the variable name); current-state replay reads which names are secret from the record's `****` entries.

Generated-secret UX and any guest-to-provider return channel stay deferred outside this implementation.
Existing plaintext local snapshots are still unsafe until the implementation is changed; do not publish them.
