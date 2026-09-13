# State model v2 - Phase 4 interface design

Pinned before Phase 4 code. Authority: `REDESIGN.md` (applied state, claims,
phases, dependency work, secret metadata), `plans/state-model-v2.md` Phase 4,
`schemas/v1/package-state.schema.json` (the state file contract),
`schemas/v1/event.schema.json` (Phase 6 will write events; Phase 4 must already
produce the fields those events need), and
`plans/state-model-v2-non-breakage.md` section 9 (no compatibility layers).

## 1. Two slices

- 4A, the substrate: host mutation lock, the physical package state file, the
  remote result channel, the dependency graph reconciliation, and the migration
  of existing successful registry observations into `applied`.
- 4B, the semantics: phase-specific resolution (install, reconfigure, verify,
  teardown), claims and compatibility, install behaviour on an existing claim,
  adoption, uninstall protection, and routing `app reconfigure|verify|teardown`.

## 2. Host mutation lock

One `flock` per `(host, package, package-instance)`, taken before any mutation
and held through every top-level and dependency result commit for that dispatch.
No nested locks: a recipe that installs a dependency re-enters through the same
dispatch, so the dependency's result is committed by the same holder.
Lock file lives beside the state file, mode 0600, wait bounded (default 120s)
with the holder's pid and start time printed on timeout.
The host lock is released before the deployment manifest lock is acquired, and
no code path may hold both.

## 3. Physical package state

One file per `(host, package, package-instance)` at the host state root, flat
`key: value` lines for Bash updatability, fields exactly the schema:
`schema_version`, `host`, `host_key`, `package`, `package_instance`, `revision`,
`applied{package_version,application_commit,at,event_id,values}`,
`last_attempt{phase,outcome,at,event_id,requested}`, `health{status,checked_at,event_id}`,
`claims[]{application,flavor,deployment,step_id,claimed_at,run_id,event_id,values}`.
Value entries carry `secret`, `declaration`, `source_form`, `reference`,
`digest`, `redacted`, never a plaintext literal secret.
`event_id` stays empty in Phase 4 (Phase 6 fills it).
Revision increments only under the host lock. A failed attempt never overwrites
`applied`; it records `last_attempt` and sets `health.status` to `degraded` or
`unknown`.

## 4. Remote result channel

The parent must learn exactly which packages a dispatch attempted, including the
dependencies `pkg_depends` pulled, without consuming recipe stdout and without
changing the package API. Transport:

- The package API appends one line per attempted package to a result file named
  by `CLOUDIFY_RESULT_FILE` when that variable is set:
  `<package>\t<package_instance>\t<parent>\t<outcome>\t<phase>`.
  One line per package, written after its recipe finishes, never a value.
- **Local dispatch**: the parent reads that file directly, because the child
  shares the filesystem.
- **Remote dispatch**: the payload exports `CLOUDIFY_RESULT_FILE` and then, as
  its last action, prints the file's contents with a sentinel prefix. The ssh
  stdout stream is piped through one filter that strips sentinel lines into a
  local per-pid result file and passes every other byte through unchanged, so
  recipe output reaches the log and the console exactly as today.
- A dispatch that reports a package absent from the precomputed dependency graph
  fails its state commit and marks the run degraded, rather than inventing a
  value after execution.
- A missing or empty result file from a successful dispatch is itself a
  degraded condition, never a silent success.

## 5. Resolution by phase

One resolver, four phase policies over the same sources (existing store names,
one pass at emit time, no second read):
- `install`: the current order, unchanged: recipe default < global < package < application < deployment < caller environment.
- `reconfigure`: deployment desired inputs and caller environment above last successful `applied` values, and `applied` above package and global defaults, so an explicit input always wins and an unchanged rerun is stable.
- `verify` and `teardown`: `applied` values are the source of truth; package and global defaults sit below them; deployment inputs and caller environment may only be used to resupply a literal secret that state holds as a digest, and a mismatch fails before mutation.
- A failed `last_attempt` never seeds a later reconfigure or teardown.
- A literal secret absent from `applied` (digest only) must be resupplied by caller or deployment input and its digest must match, otherwise the phase fails before any mutation.

## 6. Claims and compatibility

A claim is keyed by `(application, flavor, deployment, step_id)` and lives inside
the physical state file. Two packages are compatible when the package identity,
package instance, applied recipe commit or declared version, and every
configuration-affecting value match. Non-secrets compare by source value,
secret references by reference, literal secrets by digest.

- install on an existing compatible claim: no mutation, then verify.
- install whose explicit inputs differ from `applied`: fail, name the conflicting
  deployments and the differing non-secret value names, direct the operator to
  reconfigure or upgrade. Never print either side's secret content.
- an unclaimed compatible physical package takes a claim without mutation.
- an unclaimed physical package whose inputs differ needs `--adopt`; adoption
  runs configure when the package supports it and adds the claim only after
  success; a package without configure support fails adoption.
- teardown releases every claim the deployment owns, including dependency
  claims, and runs the physical uninstall only when the last claim is released
  and the pinned teardown step names the package. An unclaimed dependency stays
  installed. A destructive override exists and requires confirmation.

## 7. Registry observations

Registry records stay exactly as they are until Phase 8 removes them. Phase 4
adds a one-way migration of a successful `installed` observation into an
unclaimed `applied` state entry, run by `cloudify state migrate` (temporary,
deleted in Phase 8). Records are never a source for resolution.

## 8. Tests for the slices

4A: lock serialization and timeout, state file fields and revision, failed
attempt preserving `applied`, result-channel parsing for local and remote,
dependency reconciled against the graph, unknown reported package failing the
commit, migration idempotence.
4B: the four phase policies with a value matrix, literal-secret resupply match
and mismatch, compatible claim reuse, conflicting claim rejection before
mutation, adoption with and without configure support, teardown leaving a shared
package installed, last-claim teardown uninstalling once, destructive override,
and one real shared-dependency case in the container.
