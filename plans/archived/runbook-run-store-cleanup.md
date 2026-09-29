# Runbook structure and run-store cleanup - ARCHIVED 2026-09-29

All remaining items absorbed into plans/adoption-honesty.md (item 6) by Rachid's ruling 2026-09-29; the adoption/status/verify items moved there earlier the same day. The pre-session decisions (runs home shape, REDESIGN amendments) remain on record in REDESIGN.md.

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
- Status vocabulary rename, the adoption event producer, and `app run --phase verify` moved to `plans/adoption-honesty.md` (2026-09-29; one owner per item). This plan keeps its original run-store scope only.
- [ ] Suites: runbooks, runbook-exec, runbook-replay, deployments, state; gate; full unit; schemas green.
- [ ] Docs: GLOSSARY/REDESIGN already amended (2026-09-25); update README's runbook section if it names the field; HISTORY entry.

## Non-goals

- Phase 6 run records (status lifecycle, interruption classification, `last_run_id`) - this cleanup only relocates and re-keys the existing snapshots.
- Any change to events or the manifest beyond what the new run key requires.
