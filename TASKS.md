# TASKS

## host_vars + inline env persistence (true idempotency for cloudify config)

### Problem
Config is keyed by package, broadcast to all hosts. One shared value can't differ per node.
`cloudify --force` regenerates from shared yaml -> silent prod reconfig when values drift.

### Design (decided)
- Inline `KEY=VAL cloudify install` = user intent input (this run only).
- `~/.config/cloudify/hosts/<node>/<pkg>.yaml` = per-node persisted state.
- Cloudify writes it on every install (user does not hand-edit, except to change).
- Value precedence: `inline (this run) > per-node persisted (if exists) > package yaml default`.
- `--force` / `--clear-data` keep normal meaning (install-guard); do not change value source.
- Change intent: edit per-node yaml, OR re-run inline with new value (overwrites).
- Re-running with `--force` replays per-node values -> true idempotency, no drift.

### Work
1. Inline `KEY=VAL` arg parsing in `cloudify main()` (none exists today).
2. Per-node state writer (cloudify writes `hosts/<node>/<pkg>.yaml` on install).
3. Precedence loader: inline > per-node > package (replaces first-write-wins for these layers).
4. Reset-to-defaults escape hatch (flag or file delete) for re-adopting package default.
5. Tests: precedence, persistence, idempotency under `--force`.
6. Docs: README + AGENTS config section.

### Open
- Auditability: how to surface "node X runs topology Y" (package name? hosts/ tree?).
- Edge case (desired, not a bug): editing package yaml default after deployment does NOT propagate to deployed nodes (per-node wins).
