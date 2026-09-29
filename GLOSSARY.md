# Cloudify glossary

Concepts for the accepted state-model v2 design.

Behavior and storage rules live in `REDESIGN.md`.

## node

A machine registered in ivps that runs an instance engine and can be a Cloudify host.

ivps owns node identity, metadata, and lifecycle.

Cloudify may keep host-bound state under the directory returned by `ivps node path <node>`.

A node carries an immutable ivps id beside its mutable name (ADR-026); durable state follows the id, so renames are safe.

## instance

A container or virtual machine created by an engine on one node.

Its target form is the `Y` in `X:Y`.

ivps and the engine own its lifecycle and live machine facts.

An instance carries an immutable ivps id beside its mutable name (ADR-026).

## engine

The stack that creates and runs instances on a node, such as Incus, Docker, or Podman.

Engine metadata redesign is deferred to a separate ivps decision.

## address

A network location through which a host can be reached.

Current target resolution remains name-based and uses ivps where available.

Address-family and reachability-order normalization are deferred to a separate ivps decision.

## external host

An SSH host not registered as an ivps node or instance.

Durable Cloudify state for an external host is keyed by an accepted SSH host-key fingerprint rather than its mutable SSH alias.

## host

A place where Cloudify can dispatch a package operation.

A host is a node, an instance, or an external host.

## target host

The value typed after `--on`, resolved to one host for that command.

The existing `X`, `X:`, `X:Y`, and `:Y` grammar remains unchanged during the state-model work.

## target slot

A role name declared by an application, such as `server`, `agent`, `guest`, or `gateway`.

A target slot is bound to one resolved host.

That binding is persisted in the current deployment manifest because later lifecycle commands need it.

Changing a binding while reliances exist is an explicit migration.

## package

The unit of provisioning exposed through Cloudify's stable package API.

A package declares its recipe phases, dependencies, consumed value names, defaults, secret metadata, and optional package-instance support.

A package definition lives in git and carries no host facts.

## package instance

One independently configurable physical installation of a package on one host.

The default package-instance key is `default`.

A recipe must explicitly support package instances before a caller may choose another key.

## inventory

Two inventories, one plugged into the other: the ivps inventory is the hosts tree under `ivps node path`; the cloudify inventory is cloudify's record of what it configured, keyed per node, per instance, per deployment, per package, per package instance (ADR-027).

The cloudify inventory is a guaranteed projection of cloudify events: recomputable from the event log, exactly. Its mapping to host states is best effort, with no guarantee - the live host remains authoritative about what actually exists.

Cloudify guarantees nothing beyond what the packages and runbooks themselves declare: the recipe's verify hook is the contract, and cloudify is transport, recording, and honesty about provenance - never an independent source of verification truth.

## node record

The ivps-owned record of one node: identity, metadata, lifecycle - under the node directory `ivps node path <node>`.

## instance record

The ivps-owned record of one instance (engine, base image fingerprint, created-at; `instance.json`) under the instance directory.

## deployment record

The cloudify-owned record of one deployment: everything under `~/.config/cloudify/deployments/<app>/<flavor>/<name>/` - the deployment manifest and the run snapshots.

## package record

The cloudify-owned inventory entry for one package instance under one deployment, on one node and instance: the full key is (node, instance, deployment, package, package instance).

It contains a revision, the applied values, the last attempt, and verification health.

## physical package state

Renamed: see package record.

## applied values

The last package version and source-form values that Cloudify confirmed through a successful install or reconfigure.

A failed attempt never overwrites applied values.

Verify and teardown use applied values by default so changed defaults cannot silently alter their behavior.

## last attempt

The latest package operation Cloudify tried, including its phase, time, event, requested value metadata, and outcome.

A failed or partially observed attempt may mark package health `degraded` or `unknown` without changing the last successful applied values.

## health

The last verification observation for one package instance.

Health records the verification result and time without changing applied values.

## reliance

A statement that one deployment and stable runbook step currently relies on one package instance.

Compatible deployments may share one package instance through separate reliances.

A conflicting reliance fails before mutation.

Teardown releases every reliance owned by its deployment, including dependency reliances without uninstall actions.

It may uninstall a package only after the last reliance is released and the pinned teardown phase names that uninstall.

## value

A string consumed by a package or application step and addressed by name.

Its source form is a literal, an escaped literal, or a secret reference.

Its runtime form is the resolved plaintext made available only for execution.

Value precedence depends on the selected lifecycle phase and is defined in `REDESIGN.md`.

## default

A weak value source used when no explicit deployment input or phase-specific applied value supplies the name.

Defaults may live at recipe, global, package, or application scope.

A default is intent, not evidence that the value reached a host.

## deployment input

An explicit value the operator supplies for one named application instance.

Deployment inputs are desired configuration and remain available for first install, cross-host wiring, and later reconfigure.

They do not claim that an operation succeeded.

## secret

A value explicitly classified as sensitive by a package or application declaration.

Name-based detection is defense in depth, not the primary classification for canonical declarations, and it never produces a separate legacy class.

Events and runs never store a literal secret.

## secret reference

A source-form value that names a backend and locator without containing the secret plaintext.

The reference stays a reference in persistent state.

The resolved plaintext exists only in the private dispatch context and target configuration that needs it.

## secret backend

A resolver that converts a secret reference into plaintext at dispatch time.

Backends own secret storage while Cloudify stores the reference.

No configured backend means no lookup through that backend.

## application

A versioned runbook that coordinates packages and other operations across named target slots.

Its identity is `(application name, flavor)` and its canonical reference is `<application>/<flavor>`.

The default flavor is `default`.

An application declares inputs, mappings, targets, stable step IDs, and lifecycle phases.

An application is a plan in git, not current state.

## deployment

One named instance of an application - the long-lived thing that exists between runs, holds the desired inputs, the manifest, and the run history.

Its identity is `(application name, flavor, deployment name)`, materialized as the path `deployments/<application>/<flavor>/<deployment name>` under the state root.

A deployment id is human-set through `--name`, or generated as `<application>-<flavor>-<UTC-timestamp>` with a short suffix when needed; the same name is the same deployment (ADR-026).

A deployment has desired inputs under Cloudify configuration and a current manifest under Cloudify state.

Applied package facts remain in the package records rather than being copied into the manifest.

## deployment manifest

The small current-state rollup of one deployment, part of the deployment record: `~/.config/cloudify/deployments/<app>/<flavor>/<name>/manifest.json`.

It contains deployment identity, application commit, target bindings, lifecycle status, creation time, and last run and event IDs.

It does not contain package applied values.

A successful teardown removes the manifest only after all reliances and application-owned external resources have been released.

## manifest status

The deployment manifest's lifecycle status names the kind of the last successful state-relevant event - never a truth claim about the machine:

- `adopted` - written by deployment adoption: an operator inferred the state from the observed machine.
- `installed` - an install completed. An install whose verify stage fails stays `installed`: written but unverified - a distinction worth keeping.
- `reconfigured` - a reconfigure completed through cloudify.
- `verified` - a passing verify observed the host against the applied values, as of that moment.
- `degraded` - an attempt or the dispatch worker failed; records stand, status names the failure.

## deployment adoption

An operator action, not a mechanical cloudify action: the operator infers a deployment's state from the production machine that already runs it, and cloudify records the inference.

Captured honestly as an adoption event (writer: operator, command kind: adoption) carrying the inferred values and how they were observed - never dressed as a dispatch.

Adoption creates claims, not evidence; `verified` and `reconfigured` arrive only through real dispatches. Nothing about the machine is ever proved - the host stays authoritative.

## runbook

The Markdown program for one application flavor at `runbooks/<application>/<flavor>/runbook.md`.

Its front matter declares target slots (roles bound to hosts at run time) and, when needed, names-only application inputs and their mappings. It carries NO deployment or run id: identity comes from the path, the deployment name from `--name`, and runs identify by timestamp (the legacy `deployment:` field is removed by the run-store cleanup).

Its typed shell steps have stable IDs and belong to explicit or defaulted lifecycle phases.

The runbook controls step order and the teardown method for package and non-package resources.

## phase

One selected part of an application lifecycle.

The machine phase names are `install`, `reconfigure`, `verify`, and `teardown`.

A bare application run executes install then verify.

Reconfigure and teardown are deliberate commands.

## dispatch

One operation for one deployment, target, top-level package, package instance, and phase.

Cloudify expands the dependency graph and resolves the top-level package plus every possible dependency into one private context.

Preflight, remote forwarding, state, and event metadata consume that same context.

## dispatch context

A mode-0600 temporary artifact holding the complete inputs for one dispatch.

It contains identities plus one resolved value namespace for every package the dispatch covers (ADR-024).

It is the only value-resolution result for that dispatch and is removed after the parent process records the outcome.

## run

One execution of selected application phases - one playing of the runbook.

A run is a LOG ENTRY of its deployment, not a thing the operator names: the deployment is the persistent instance (chosen with `--name`), runs are its history, and a run identifies itself by its UTC timestamp.

Runs accumulate; none replaces another. Replay addresses them by time: the newest by default, or `--at <timestamp prefix>`.

Its record is written before the first selected step and ends as `succeeded`, `failed`, or `interrupted`.

A run stores identity and lifecycle metadata but no resolved values or automatic step outputs.

## event

An immutable audit record for one observed attempt or state transition.

An event links a tool, tool version, writer, run, step, deployment, subject, phase, outcome, and state revisions.

It stores value names, sources, references or digests, the source form of non-secret values, and secret flags, without raw output or literal secrets.

Events help detect interrupted state commits but are not executable commands.

## revision

A monotonically increasing number on one package record.

A local host mutation lock serializes package revision changes for that host.

No global total event order is required.

## state check

A read-only comparison of events and current state that reports missing events, unapplied events, duplicate revisions, and regressed revisions.

Repair requires an explicit flag and only applies deterministic local state transitions.

## reconfigure

The explicit application phase that changes an existing relied-on package instance.

It may rewrite configuration, restart services, rotate secrets, or update artifacts.

It must not silently change hosts, package ownership, or persistent-data retention.

## teardown

The explicit application phase that releases the deployment's resources and package reliances.

Reliances identify the packages owned or shared by the deployment.

The pinned runbook supplies teardown actions and order.

A shared package is uninstalled only after its final reliance is released.

## upgrade

An explicit migration from one application commit to another for an active deployment.

Upgrade handles added, changed, and removed stable runbook steps before replacing the manifest's pinned commit.

An ordinary reconfigure never performs an implicit upgrade.

## migration bridge

A temporary one-shot command that reads one old artifact class, desired inputs, registry records or snapshots, and writes the v2 equivalent.

A bridge is dry-run first, idempotent, prints names and paths without values, and preserves only facts the old artifact proves.

Runtime commands never consult a bridge or an old path, and every bridge, old reader and migration fixture is deleted once the inventory reports zero old artifacts.
