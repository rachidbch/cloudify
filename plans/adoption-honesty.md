# Adoption honesty and status vocabulary - session plan (queued, not started)

Design only. No implementation in this plan's commit; every item names its
files, its acceptance, and its tests. Normative basis: GLOSSARY entries as
landed 2026-09-29 (`cloudify inventory`, `package record`, `applied values`,
`deployment adoption`, `manifest status`) and the rulings of 2026-09-29
(adoption-command shape accepted incl. values-as-input; manifest ruled a
rebuildable cache outside the projection path). ROADMAP "State-tree hygiene"
cross-references this plan.

This plan takes over the adoption/status/verify items previously parked in
`plans/runbook-run-store-cleanup.md` (handed back there via a pointer; that
plan keeps its original run-store scope only).

## Sequence rationale

Events and vocabulary first (nothing else can be honest without them), the
status machine second (the adoption command records its outcome in it), the
adoption command third, the manifest cache fourth (consumes the status
machine), then runbook verify, hygiene, and the affine backfill last.

## 1. Glossary corrections (docs, small)

- Fix the deployment-record anchor: the manifest lives at
  `~/.local/state/cloudify/deployments/<app>/<flavor>/<name>/manifest.json`;
  deployment inputs live under `~/.config/cloudify/deployments/`. The record
  spans both trees; say so.
- Amend `deployment manifest`: a rebuildable cache outside the projection
  path; fields split declared (identity, bindings, created-at) vs derived
  (status, last event id); never a source.
- Acceptance: every record/manifest term anchored with example absolute
  paths; no term left that poses as machine truth.

## 2. Event schema: the operator writer (small-medium)

Files: `schemas/v1/event.schema.json` + fixtures, `lib/state.sh` (event
body builder).

- Writer vocabulary gains an operator discriminator beside the machine
  identity (host/boot/pid): an adoption event names who inferred, not which
  process ran. Shape: `writer: {kind: "operator", name: "<operator>"}` vs
  the existing process identity.
- `command_kind: "adopt"` and the phase-less semantics already exist in the
  schema; no kind additions needed.
- Acceptance: schema validates an operator-writer adoption event; the builder
  produces it; `schemas/v1/validate.sh` green on new fixtures.

## 3. The status machine (medium-large)

Files: `lib/worker.sh` (status decision), `lib/state.sh`
(`cloudify_state_deployment_create`, direct synthesis), `lib/runbooks.sh`,
`lib/deployments.sh` (show/consumers), manifest schema if it pins a status
enum, all pinning tests.

- Status is the kind of the last successful state-relevant event, per
  GLOSSARY `manifest status`: `adopted | installed | reconfigured | verified
  | degraded`. `applying` and `active` die.
- The failure split (the real logic): a package attempt failure degrades;
  an install whose verify STAGE fails stays `installed` with failing health -
  written-but-unverified is information, not a downgrade. The worker must
  distinguish attempt-failure from verify-stage-failure before choosing.
- Verify-pass sets `verified`; reconfigure sets `reconfigured`; a later
  organic dispatch overwrites per the same rule.
- Migration: on-disk manifests regraded (`active`/`applying` -> the new
  words by event-log inspection; no event -> `adopted` only where an
  adoption event exists, else rebuilt per item 5).
- Acceptance: worker suites pin every transition incl. the install-stays-
  installed case; `deployment show` renders the new words; gate green
  (statuses never enter payload bytes).

## 4. The adoption command (medium-large)

Surface: `cloudify adoption record <app>/<flavor>/<name> --on <target>`
( final verb/naming at implementation review).

Inputs: the deployment identity, the target, and the operator's inferred
values (stdin: name, value, provenance/source), package version, notes.

Flow (one command, in order):
1. Write the package records in mechanical shape (revision 1, applied values
   with provenance fields, `last_attempt` null, health unknown) - the
   operator supplies the inference, cloudify supplies the shape. No more
   hand-carved `state.json`.
2. Write the adoption event: writer `operator`, kind `adopt`, values, an
   honest summary string supplied by the operator.
3. Fire the seeded verify dispatch (read-only; the machine's first cloudify
   touch is a read) and record the outcome: pass -> health ok, status
   `verified`; fail -> health records the failure, status stays `adopted`.
   A failed verify never unwrites the adoption.
4. Pin no commit: the manifest's derived fields come from events only.

Affine backfill runs through this command (see item 8).

Acceptance: unit tests on record/event shape (operator writer), the
verify-outcome recording, and the fail-leaves-adoption-standing path; one
container e2e on a fixture package.

## 5. Manifest as rebuildable cache (medium)

Files: `lib/state.sh` (manifest write/rebuild), `lib/worker.sh` (post-dispatch
maintenance), a new rebuild surface (`cloudify deployment rebuild-manifest`
or equivalent).

- Declared fields (identity, bindings, created-at) come from deployment
  inputs; derived fields (status, last event id) from the event log. The
  adoption path writes no `application_commit`.
- Rebuild recomputes derived fields from the event log and stamps the
  manifest with the event id it was rebuilt from; a lost or corrupt manifest
  is recoverable, never fatal, never a source.
- Auto-rebuild on staleness: design choice left to implementation review
  (explicit command is the minimum; rebuild-on-read-when-stale is the
  opt-in).
- Acceptance: rebuild determinism - after every suite action, rebuild output
  equals the maintained manifest; consumers never read the manifest as a
  source of applied values.

## 6. `app run --phase verify` (medium)

Files: `lib/runbooks.sh` (phase selection), the runbook executor.

- Re-runs can select the verify steps only - the seeded, read-only drift
  check over the whole application deployment, no operator env bits. This is
  the primary verification use (package-level verify exists; runbook-level
  does not).
- Configure/teardown phase selection stays out of scope (noted for later).
- Acceptance: runbook-exec suites pin verify-only selection; the two-host
  e2e remains green.

## 7. State-tree hygiene (medium)

Files: router/lib surface for `deployment delete`; sweeps in state
maintenance paths.

- `deployment delete`: reliance-checked sweep of manifest + package records
  (queued since the worker-wiring handoff).
- `_direct` accumulation: every bare dispatch leaves a `_direct` manifest
  forever - sweep policy by age at synthesis or maintenance time.
- Deleted-instance residue: records survive under instance dirs of deleted
  instances - sweep keyed to ivps instance liveness (an offline instance is
  not deleted; liveness is ivps's word, not a ping).
- Acceptance: unit tests per sweep; the twin residue on this controller is
  removed by the implementation, not by hand.

## 8. Affine close-out (small, last)

- Backfill the production affine deployment (cloudai:affine, deployment
  affine/default/main) through the adoption command: inferred values from
  the existing record (port 8787, dir, recipe-sourced), honest summary.
- The command's verify step runs read-only against production - no restart;
  a pass grades the manifest `verified`.
- PKG-ADOPTIONS tick, HISTORY entry. The external baseline backup stays with
  Rachid's agent per the README contract.

## Non-goals

- Full event-sourcing of bindings or creation (the manifest is a helper -
  ruled 2026-09-29).
- Configure/teardown phase selection for `app run`.
- Any change to deployment input stores, var sources, or payload bytes.

## Gates

- `task gate` after items 2, 3, 5 (schema, status writers, manifest paths).
- Full unit + scoped integration at session end; the two-host e2e as the
  exit gate (it pins verify behavior end to end).
- HISTORY/LOGS entries per item; VERSION bump at session close (MINOR:
  behavior changes).
