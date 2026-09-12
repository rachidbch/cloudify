# Cloudify glossary

Concepts for the accepted state-model v2 design.

Behavior and storage rules live in `REDESIGN.md`.

## node

A machine registered in ivps that runs an instance engine and can be a Cloudify host.

ivps owns node identity, metadata, and lifecycle.

Cloudify may keep host-bound state under the directory returned by `ivps node path <node>`.

Stable node IDs and rename migration are deferred to a separate ivps decision.

## instance

A container or virtual machine created by an engine on one node.

Its target form is the `Y` in `X:Y`.

ivps and the engine own its lifecycle and live machine facts.

Stable instance IDs are deferred to a separate ivps decision.

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

## target reference

A token typed after `--on` and resolved to one host for that command.

The existing `X`, `X:`, `X:Y`, and `:Y` grammar remains unchanged during the state-model work.

## target slot

A role name declared by an application, such as `server`, `agent`, `guest`, or `gateway`.

A target slot is bound to one resolved host.

That binding is persisted in the current deployment manifest because later lifecycle commands need it.

Changing a binding while active claims exist is an explicit migration.

## package

The unit of provisioning exposed through Cloudify's stable package API.

A package declares its recipe phases, dependencies, consumed value names, defaults, secret metadata, and optional package-instance support.

A package definition lives in git and carries no host facts.

## package instance

One independently configurable physical installation of a package on one host.

The default package-instance key is `default`.

A recipe must explicitly support package instances before a caller may choose another key.

## physical package state

Cloudify's last confirmed observation of one package instance on one host.

One physical installation has one state record even when several deployments use it.

The record contains a revision, the last successful applied state, the last attempt, verification health, and active deployment claims.

The live host remains authoritative about what actually exists.

## applied state

The last package version and source-form values that Cloudify confirmed through a successful install or reconfigure.

A failed attempt never overwrites applied state.

Verify and teardown use applied state by default so changed defaults cannot silently alter their behavior.

## last attempt

The latest package operation Cloudify tried, including its phase, time, event, requested value metadata, and outcome.

A failed or partially observed attempt may mark package health `degraded` or `unknown` without changing the last successful applied values.

## health

The last verification observation for one physical package instance.

Health records the verification result and time without changing applied values.

## claim

A statement that one deployment and stable runbook step currently relies on one physical package instance.

Compatible deployments may share one package instance through separate claims.

A conflicting claim fails before mutation.

Teardown releases every claim owned by its deployment, including dependency claims without uninstall actions.

It may uninstall a physical package only after the last claim is released and the pinned teardown phase names that uninstall.

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

Name-based detection is defense in depth, not the primary classification for canonical declarations.

Legacy declarations use the heuristic with a migration warning during the compatibility period.

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

One named instance of an application.

Its identity is `(application name, flavor, deployment name)`.

The default deployment name is `default`.

A deployment has desired inputs under Cloudify configuration and a current manifest under Cloudify state.

Applied package facts remain in physical package state rather than being copied into the manifest.

## deployment manifest

The small current-state record for one deployment.

It contains deployment identity, application commit, target bindings, lifecycle status, creation time, and last run and event IDs.

It does not contain package applied values.

A successful teardown removes the manifest only after all claims and application-owned external resources have been released.

## runbook

The Markdown program for one application flavor at `runbooks/<application>/<flavor>/runbook.md`.

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

It contains identities plus one source-form and runtime-value view for the top-level package and each possible dependency.

It is the only value-resolution result for that dispatch and is removed after the parent process records the outcome.

## run

One execution of selected application phases.

Its record is written before the first selected step and ends as `succeeded`, `failed`, or `interrupted`.

A run stores identity and lifecycle metadata but no resolved values or automatic step outputs.

## event

An immutable audit record for one observed attempt or state transition.

An event links a tool, writer, run, step, deployment, subject, phase, outcome, and state revisions.

It stores value names, sources, references or digests, and secret flags without raw output or literal secrets.

Events help detect interrupted state commits but are not executable commands.

## revision

A monotonically increasing number on one physical package state record.

A local host mutation lock serializes package revision changes for that host.

No global total event order is required.

## state check

A read-only comparison of events and current state that reports missing events, unapplied events, duplicate revisions, and regressed revisions.

Repair requires an explicit flag and only applies deterministic local state transitions.

## reconfigure

The explicit application phase that changes an existing claimed package instance.

It may rewrite configuration, restart services, rotate secrets, or update artifacts.

It must not silently change hosts, package ownership, or persistent-data retention.

## teardown

The explicit application phase that releases the deployment's resources and package claims.

Claims identify the physical packages owned or shared by the deployment.

The pinned runbook supplies teardown actions and order.

A shared package is uninstalled only after its final claim is released.

## upgrade

An explicit migration from one application commit to another for an active deployment.

Upgrade handles added, changed, and removed stable runbook steps before replacing the manifest's pinned commit.

An ordinary reconfigure never performs an implicit upgrade.

## compatibility period

The release interval in which Cloudify reads both legacy and v2 deployment stores, runbooks, registry records, and snapshots.

New writers switch only after schema, migration, and parity gates pass.

Old readers are removed in a later explicitly approved release.
