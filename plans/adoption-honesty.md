# Adoption honesty and status vocabulary - session plan (CURRENT)

Progress (2026-09-29, session one): items 1-9 LANDED (commits d74c824..a4ddfee); item 10 PARTIAL (youtube-mcp adopted + verified, census five dispositioned; hermes round two remains); item 11 NOT STARTED. Also open: three pre-existing shell-router reds (repair map in LOGS 2026-09-29, session close). Handoff: ~/.pi/handoffs/2026-09-29-cloudify-adoption-honesty-items-1-9-census-done.md

Design first; implementation in this session per item, red test first. Normative basis: GLOSSARY entries as landed 2026-09-29 (`cloudify inventory`, `package record`, `applied values`, `deployment adoption`, `manifest status`), the REDESIGN amendments of 2026-09-29 (manifest as rebuildable cache, status vocabulary, adoption pins no commit), and the rulings of 2026-09-29 (adoption-command shape accepted incl. values-as-input; manifest ruled a helper outside the projection path). ROADMAP "State-tree hygiene" cross-references this plan.

Absorbed by Rachid's ruling (2026-09-29):
- All remaining items of `plans/runbook-run-store-cleanup.md` (archived with a pointer) - the runs home, front-matter removal, flat-store migration, and dotted-id dissolution are prerequisites of this plan's own items.
- The closure of `plans/state-model-v2-recovery.md` (implementation complete; its independent-review exit gate is this plan's final phase).
- The continuation of the other adoptions (PKG-ADOPTIONS is the worklist; this plan owns the umbrella).

## Sequence rationale

Events and vocabulary first (nothing else can be honest without them), the status machine second (the adoption command records its outcome in it), the adoption command third, the manifest cache and run-store normalization fourth (they consume the status machine and feed the verify re-run), then runbook verify, hygiene, the adoptions, and the reviews last - they judge everything this plan ships.

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

## 6. Run-store normalization (absorbed from the archived cleanup plan; medium)

Files: `lib/runbooks.sh` (engine, parse), runbook fixtures, `lib/deployments.sh`.

- Runs home: derive the run key from identity (path + name + timestamp); every writer moves to the per-deployment state-tree home (`deployments/<a>/<f>/<n>/runs/<utc>.json`, ruled 2026-09-27, REDESIGN Data homes). No `CLOUDIFY_DEPLOYMENT` id threading. Prerequisite of item 7: the verify re-run writes run snapshots.
- Runbook parse: drop `deployment:` from the front-matter contract; validation rejects it with a named error pointing at the removal. Migrate the two runbooks (affine, xfce-guacamole).
- Migrate the legacy flat store `~/.config/cloudify/deployments/<id>/runs/` into the state tree; delete the flat dirs.
- Dissolve the dotted-id lookup workaround: `show`/`replay` resolve from identity (path + explicit `--name` or manifest listing), never by decoding ids. Prerequisite of item 8: the adoption close-out confirms through `deployment show`.
- Acceptance: runbooks/runbook-exec/runbook-replay/deployments/state suites green; gate; schemas; README's runbook section updated if it names the removed field.

## 7. `app run --phase verify` (medium)

Files: `lib/runbooks.sh` (phase selection), the runbook executor.

- Re-runs can select the verify steps only - the seeded, read-only drift
  check over the whole application deployment, no operator env bits. This is
  the primary verification use (package-level verify exists; runbook-level
  does not).
- Configure/teardown phase selection stays out of scope (noted for later).
- Acceptance: runbook-exec suites pin verify-only selection; the two-host
  e2e remains green.

## 8. State-tree hygiene (medium)

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

## 9. Affine close-out (small)

- Backfill the production affine deployment (cloudai:affine, deployment
  affine/default/main) through the adoption command: inferred values from
  the existing record (port 8787, dir, recipe-sourced), honest summary.
- The command's verify step runs read-only against production - no restart;
  a pass grades the manifest `verified`.
- PKG-ADOPTIONS tick, HISTORY entry. The external baseline backup stays with
  Rachid's agent per the README contract.

## 10. The other adoptions (umbrella; PKG-ADOPTIONS is the worklist)

- Hermes round two per PKG-ADOPTIONS: value investigation on `cloudai:hermes`, `hermes-svc`, `openwebui-hermes`; the hermes pair's re-entry conditions (ROADMAP "Hermes pair out of test scope") are in scope here - public-mode auth design, the claim-path pinning test, the openwebui health classification - so the pair can return to the integration suite.
- Census retry for the flapped five when cloudai settles (`cloudai:piface`, `cloudai:pir`, `cloudai:seed`, `cloudai:xf-test`, `cloudai:youtube-mcp`) - each becomes either an adoption through the item-4 command or an explicit exclusion.
- Every adoption in this phase runs through the adoption command - no hand-carved records after affine.

## 11. Exit gate: independent fresh-context reviews (absorbed from the recovery plan)

- Spawn a fresh-context SPEC reviewer on a different backend/model to evaluate every shipped behavior against `REDESIGN.md`, the ADRs, schemas, GLOSSARY and this plan; if no different backend is available, stop for an explicit human waiver.
- Require exactly `PASS` with no actionable feedback.
- Spawn a separate fresh-context Technical reviewer on another backend/model (correctness, modularity, security, Bash safety, error propagation, DRY, KISS, maintainability, locking, atomic writes, test quality); same waiver rule, same exact-PASS rule.
- Actionable feedback: fix, rerun the affected ladder, rerun both reviews from fresh contexts. Budgets per AGENTS SDLC (SPEC: one review/fix/verify pass; Technical: at most three), then escalate to Rachid - never another loop.

### Final closure (replaces the recovery plan's)

- Full ladder green on final HEAD: lint, gate, full unit, full integration (hermes pair re-entry included if item 10 landed it), two-host e2e, k3s e2e.
- `git status --short` clean; `PLAN.md` resolves to this plan; no stale checked box.
- Archive `plans/state-model-v2-recovery.md` and this plan; repoint `PLAN.md` per Rachid's next call.
- VERSION bump (MINOR: behavior changes), HISTORY/LOGS current.

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
