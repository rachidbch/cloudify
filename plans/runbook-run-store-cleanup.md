# Runbook structure and run-store cleanup (agreed 2026-09-25)

Trigger: the affine adoption exposed identity confusion (the runbook `deployment:` field, the flat run store, the dotted-id lookup workaround). Decision recorded in REDESIGN (Cross-host deployment glue, 2026-09-25 amendment): no deployment or run id in the runbook; runs identify by timestamp under their deployment.

## Open decision (session start)

- Runs home shape: per-deployment `deployments/<a>/<f>/<n>/runs/<utc>.yaml` (walking one deployment tells its whole story; matches Rachid's instinct) versus the currently sketched root-level `runs/<run-id>.json`. Recommendation: per-deployment. Events stay at the root (global audit).

## Session checklist (red test first, per item)

- [ ] Decision: runs home shape (above), recorded in REDESIGN the same commit.
- [ ] Engine: derive the run key from identity (path + name + timestamp); every writer moves to the state-tree home. No `CLOUDIFY_DEPLOYMENT` id threading.
- [ ] Runbook parse: drop `deployment:` from the front-matter contract; validation rejects it with a named error pointing at the removal.
- [ ] Migrate the two runbooks (affine, xfce-guacamole): field removed.
- [ ] Migrate the legacy flat store `~/.config/cloudify/deployments/<id>/runs/` (today: E2E snapshots only) into the state tree; delete the flat dirs.
- [ ] Dissolve the dotted-id lookup workaround: `show`/`replay` resolve from identity (path + explicit `--name` or manifest listing), never by decoding ids.
- [ ] Suites: runbooks, runbook-exec, runbook-replay, deployments, state; gate; full unit; schemas green.
- [ ] Docs: GLOSSARY/REDESIGN already amended (2026-09-25); update README's runbook section if it names the field; HISTORY entry.

## Non-goals

- Phase 6 run records (status lifecycle, interruption classification, `last_run_id`) - this cleanup only relocates and re-keys the existing snapshots.
- Any change to events or the manifest beyond what the new run key requires.
