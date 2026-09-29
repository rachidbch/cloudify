# Runbook structure and run-store cleanup (agreed 2026-09-25)

Trigger: the affine adoption exposed identity confusion (the runbook `deployment:` field, the flat run store, the dotted-id lookup workaround). Decision recorded in REDESIGN (Cross-host deployment glue, 2026-09-25 amendment): no deployment or run id in the runbook; runs identify by timestamp under their deployment.

## Decided before the session (Rachid, 2026-09-27)

- Runs home: per-deployment `deployments/<a>/<f>/<n>/runs/<utc>.json` - walking one deployment tells its whole story; JSON per REDESIGN ("runs and events use schema-versioned JSON"); events stay at the root as the global audit. Recorded in REDESIGN (Data homes) the same day. Events stay at the root (global audit).

## Session checklist (red test first, per item)

- [x] Decision: runs home shape - per-deployment (Rachid, 2026-09-27), recorded in REDESIGN with the decision commit.
- [ ] Engine: derive the run key from identity (path + name + timestamp); every writer moves to the state-tree home. No `CLOUDIFY_DEPLOYMENT` id threading.
- [ ] Runbook parse: drop `deployment:` from the front-matter contract; validation rejects it with a named error pointing at the removal.
- [ ] Migrate the two runbooks (affine, xfce-guacamole): field removed.
- [ ] Migrate the legacy flat store `~/.config/cloudify/deployments/<id>/runs/` (today: E2E snapshots only) into the state tree; delete the flat dirs.
- [ ] Dissolve the dotted-id lookup workaround: `show`/`replay` resolve from identity (path + explicit `--name` or manifest listing), never by decoding ids.
- [ ] Manifest status vocabulary (ruling 2026-09-29, GLOSSARY "manifest status"): worker + runbook engine write `adopted | installed | reconfigured | verified | degraded` - the kind of the last successful state-relevant event (an install whose verify stage fails stays `installed`). Migration for existing manifests (`applying`/`active` → the new words; affine's becomes `adopted`). Consumers (deployment show, guard) updated.
- [ ] Adoption event producer (ruling 2026-09-29, GLOSSARY "deployment adoption"): `cloudify adoption record` (or the adoption subcommand shape chosen then) writes the operator-inference event (writer: operator, kind: adoption) feeding the same projection - manual content, mechanical capture. Backfills affine's adoption (currently a hand-shaped event + `active` manifest).
- [ ] `app run --phase verify`: runbook runs select their verify steps only - the seeded, read-only drift check without the operator env bits (the tuple is still manual for bare commands).
- [ ] Suites: runbooks, runbook-exec, runbook-replay, deployments, state; gate; full unit; schemas green.
- [ ] Docs: GLOSSARY/REDESIGN already amended (2026-09-25); update README's runbook section if it names the field; HISTORY entry.

## Non-goals

- Phase 6 run records (status lifecycle, interruption classification, `last_run_id`) - this cleanup only relocates and re-keys the existing snapshots.
- Any change to events or the manifest beyond what the new run key requires.
