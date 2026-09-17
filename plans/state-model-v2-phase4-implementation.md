# Phase 4 implementation plan

Parent plan: `plans/state-model-v2-recovery.md` (the single entry point, reached through `PLAN.md`).
Specification: `plans/state-model-v2-phase4-design.md` (redone revision 8, frozen; any change surfaces to Rachid first).
Decision: ADR-026 (deployment-first per-node inventory in the ivps tree) and ADR-027 (inventory naming and layout, event value content, `_direct` deployment synthesis).

This subplan sequences and gates the implementation. It holds no design: the specification and REDESIGN do.

## Standing rules (inherited, not restated)

- Review budgets per reviewed artifact (SDLC rule): SPEC 1 review + 1 fix + 1 verification; Technical up to 3 review/fix/verify passes; a still-failing verification escalates to Rachid.
- The design-review budgets for this phase are exhausted and closed (parent plan ledger). Implementation-diff reviews get fresh budgets per artifact.
- One red test, minimum green, refactor. Tests run in `cloudai:cloudify`; `task sync` before container runs; push before remote hosts pull.
- Fragile-surface rule where touched (`lib/remote.sh`, `lib/context.sh`, `lib/vars.sh`): name the invariants, run `task gate`, goldens byte-identical.
- Normative-file changes only with Rachid's consent; REDESIGN/ADR land in the same commit as the authorizing decision.
- Drift rule: a deviation from an agreed decision is surfaced before it is carved.

## Dependency

- **ivps deliverable**: immutable id per node and instance; `ivps node path` keyed by the id. Owned by the ivps repo; must start before 4.2 and land before the first inventory write.

## 4.0 Gates (before any code)

- [ ] Fragile-surface: name the invariants touched by the two flat-context field shapes and the result-line channel; run `task gate`; the eight payload goldens byte-identical. (Format consents recorded 2026-09-15.)
- [ ] Confirm the REDESIGN inventory-contents amendment stands (the inventory holds the package version; no commit field).

## 4.1 State and event substrate

- [ ] Red schema fixtures: non-null event IDs everywhere new; revision 0 invalid; `package_instance` charset; null-commit/`development_override` rules; migration `origin` bounded; migration inventory carve-outs (null step ID, null `last_attempt`, null version when unproven).
- [ ] Flat context: `value.<NAME>.declaration` and `package.<PACKAGE>.instance` fields; `cloudify_context_validate` accepted-shape extension. (Fragile gate; consent recorded.)
- [ ] Generalize the one jq schema validator into `cloudify_state_validate_file <schema> <file>`; manifest validation delegates.
- [ ] Shared ID helper (event IDs, collision retry) and writer-identity helper.
- [ ] Immutable event rendering; hard-link create-if-absent; bounded retry; directory flush.
- [ ] Inventory rendering (deployment + package + instance identity; `applied`, `last_attempt`, `health`); event-first replacement; re-read before success.
- [ ] Subject-level gap detection (inventory pointing at a missing event blocks mutation).
- [ ] Slice exit: focused state/event suites green; `bash schemas/v1/validate.sh` green; no inventory writer landed before the event writer is green.

## 4.2 Immutable identity, instances, and paths

- [ ] Adopt the ivps immutable ids; per-node path helpers (`deployments/`, `cloudify/` lock directory).
- [ ] `.package-instance` contract: file names the instance variable; variable must appear in `.remote-vars`; validation and tests.
- [ ] Instance identity resolved from the context (`package.<PACKAGE>.instance`).
- [ ] External durable state rejected before remote execution; README or release note covering the external-host suspension, the local-inventory prerequisite, executed-commit freshness, and clock-sync expectation.
- [ ] Slice exit: focused identity/path suites green.

## 4.3 Host lock, versions, and result lines

- [ ] Freeze tests first: lock, result-line validation, matching, reconciliation, bounds, executed-code check.
- [ ] The dispatch worker and the bounded host lock (metadata in the lock file; timeout prints it).
- [ ] The `_direct` synthesis: bare install creates the generated deployment under the reserved namespace with the virtual `direct` step and manifest under the uniform commit rule; `--name` reuses; bare never matches.
- [ ] Deployment matching: same configuration converges; no match creates a generated-name deployment, printed.
- [ ] `pkg_version()` sweep across every recipe in `pkg/` (`none` stores null; failures yield `version=unknown` and a failed attempt); result emission around package attempts, including native subjects and framework work.
- [ ] The pass-through result stage (read idiom, return discipline, ERR-trap inhibited); line-by-line validation; the executed-code check.
- [ ] Reconciliation before ordered commits (classifier buckets; membership; body order).
- [ ] Delete the runtime registry writer; split the goldens (payload half untouched; registry fixtures to migration).
- [ ] Prove unconditional context cleanup and byte-identical payload goldens.
- [ ] Slice exit: focused lock/result suites green; `task gate` green.

## 4.4 Phase-specific resolution

- [ ] Gate: the reconfigure ladder insert and the `applied` source label hold Rachid's go (fragile change).
- [ ] Applied source forms below explicit reconfigure sources; context machinery extended to the paths that still lack it.
- [ ] Verify and teardown seed from `applied` only.
- [ ] Matching resupply for redacted literals; digest-mismatch rejection.
- [ ] Install never applies changed explicit inputs - REDESIGN's rule stands.
- [ ] Slice exit: focused resolution suites green.

## 4.5 Guard and adoption

- [ ] Gate: the REDESIGN subject-scope qualifier alignment has landed.
- [ ] Node-scan guard checks for requested top-level packages under the host lock; commit-time checks for dependency results.
- [ ] Adoption (`--adopt`): configure-based takeover, inventory only after success, unsupported configure refuses.
- [ ] Slice exit: focused guard suites green.

## 4.6 Teardown, override, and failure state

- [ ] Inventory release on shared teardown; last-reliance uninstall ordering.
- [ ] The `CLOUDIFY_BREAK_RELIANCES` override: typed confirmation, one naming event and release per displaced deployment, never for application teardown.
- [ ] The commit-drift gate (proved commit equals manifest commit; null-commit manifest gets the unreproducible message).
- [ ] Failed attempts preserve `applied`; degraded or unknown health recorded through event-backed transitions.
- [ ] Slice exit: focused teardown/override suites green.

## 4.7 Migration and the Phase 4 gate

- [ ] Consume the old-registry fixtures staged in 4.3.
- [ ] `cloudify state migrate-registry`: dry-run default, `--apply`, mapped deployment directories, prove-only classification, `@base64:` transport decoded, idempotent, report-not-migrate rules.
- [ ] Focused suites (package API, context, state, event, inventory, registry, router, runbook).
- [ ] One real shared-dependency case after L0-L3 pass.
- [ ] `task lint` and the full unit suite.
- [ ] The Phase 4 E2E scenarios (two disposable hosts; install, verify, reconfigure, interruption, shared inventory, conflict, teardown).
- [ ] Every disposable resource torn down; host policy proven restored.
- [ ] Final SPEC and Technical implementation reviews of the real diff (fresh budgets per the SDLC rule), both `PASS` with evidence.
- [ ] Phase commit only when every line above is green.

## Review budget ledger (implementation-diff reviews; per artifact)

- (empty - entries added as implementation reviews run)

## Closure

- [ ] Every disposable resource removed; `git status --short` clean.
- [ ] Outcome recorded in the parent plan's Phase 4 section with evidence; this subplan moves to `plans/archived/`.
