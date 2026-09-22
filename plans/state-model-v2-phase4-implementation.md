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

- [x] Fragile-surface: invariants named below (2026-09-18); `task gate` green on 64dad35 tree (142 ok / 0 not ok, rc 0; the eight payload goldens byte-identical). (Format consents recorded 2026-09-15.)
- [x] Confirm the REDESIGN inventory-contents amendment stands: REDESIGN.md:353 (`applied` holds the required package version, source-form values, time), :369 (version not compared), per-package commit absent. (2026-09-18.)

Invariants named (2026-09-18, before any 4.1 edit):

- Flat-context field shapes (`lib/context.sh`: `value.<NAME>.declaration`, `package.<PACKAGE>.instance`):
  1. The claim ledger and the provenance file stay files, never arrays (six emptiness tests on the ledger scalar).
  2. The claim ledger's `sort -u` iteration order is load-bearing: the envsubst allow-list is recovered from it (`lib/remote.sh:123`) and it pins the payload export order - the eight byte-exact goldens prove it.
  3. The context is written once, after the walk completes, never incrementally.
  4. First-write-wins claiming is preserved; the new fields are derived during the existing single resolution and never re-read a value source.
  5. `cloudify_context_validate`'s accepted-shape extension only admits the two new field names; required-field and well-formedness checks are not weakened.
- Result-line channel (`lib/remote.sh`):
  6. The streamed-log chain (payload `exec > >(tee -a "$CLOUDIFY_LOG_FILE") 2>&1`, SSH channel, host-prefix stages, local protected log) stays unbuffered and unfiltered; the tap is pass-through and copies matches aside.
  7. The tap stage returns 0 unconditionally in condition context with the ERR trap inhibited inside its subshell; the router's `trap cleanup SIGINT SIGTERM ERR EXIT` can never fire mid-stream.
  8. The payload template and the eight payload goldens stay byte-identical; recipe stdin and stdout bytes are unchanged.

## 4.1 State and event substrate

- [x] Red schema fixtures: non-null event IDs everywhere new; revision 0 invalid; `package_instance` charset; null-commit/`development_override` rules; migration `origin` bounded; migration inventory carve-outs (null step ID, null `last_attempt`, null version when unproven). (efcff74, validate.sh 17/34/0)
- [x] Flat context: `value.<NAME>.declaration` and `package.<PACKAGE>.instance` fields; `cloudify_context_validate` accepted-shape extension. (2455d23; gate 146/0)
- [x] Generalize the one jq schema validator into `cloudify_state_validate_file <schema> <file>`; manifest validation delegates. (1e929eb)
- [x] Shared ID helper (event IDs, collision retry at create) and writer-identity helper. (4.1.4)
- [x] Immutable event rendering; hard-link create-if-absent; bounded retry; directory flush. (37d0253)
- [x] Inventory rendering (deployment + package + instance identity; `applied`, `last_attempt`, `health`); event-first replacement; re-read before success. (4.1.6)
- [x] Subject-level gap detection (inventory pointing at a missing event blocks mutation). (4.1.7 + apply refusal)
- [x] Slice exit: focused state/event suites green; `bash schemas/v1/validate.sh` green; no inventory writer landed before the event writer is green. (event 9/9, state 18/0, full suite later 680/0)

## 4.2 Immutable identity, instances, and paths

- [x] Adopt the ivps instance records (ivps ADR-010 merged 13dcb59); `ivps node path <node>:<instance>` id-keyed; per-node path helpers (`deployments/`, `cloudify/` lock directory). (319c4cd, inventory.bats 3/3)
- [x] Host origin and continuity (ADR-028): `cloudify/host.json` written once (origin discovered/asserted/unknown, continuity host id + boot id); check refuses rewound-or-replaced. Dispatch wiring lands with the 4.3 worker. (5c40bd7)
- [x] `.package-instance` contract: file names the instance variable; variable must appear in `.remote-vars`; validation and tests. (3ed6e7c, context.bats 27-29)
- [x] Instance identity resolved from the context (`package.<PACKAGE>.instance`). (3ed6e7c)
- [x] External durable state rejected (structural refusal in the path helpers; named local-inventory error) + README Phase 4 note. Worker-level wiring lands with 4.3. (3ed6e7c)
- [x] Slice exit: focused identity/path suites green (inventory 3/3, context 34/0).

## 4.3 Host lock, versions, and result lines

- [x] Freeze tests first: lock tests frozen (bounded holder timeout, metadata, release); result-line freeze (results.bats 20/20), reconciliation freeze (results-reconcile.bats 9/9), matching freeze still pending (lands with the matching slice).
- [x] The bounded host lock landed (9fce0e8: flock fd 200, holder metadata, timeout prints it) and the dispatch worker wiring landed (b262716: lock held through collection/reconciliation/verdict/commits, released before the manifest lock, test-only no-both-locks assertion, off-graph dependency = fail-closed empty values + degraded run, executed-code mismatch = one deployment-subject event recording the executed commit and no inventory).
- [x] The `_direct` synthesis: bare install creates the generated deployment under the reserved namespace with the virtual `direct` step and manifest under the uniform commit rule; `--name` reuses; bare never matches. (state.sh: generated_name/synthesize/resolve; reserved step ids defaults/init/direct rejected in runbook parse; direct-synthesis.bats 7/7)
- [x] Deployment matching: same configuration converges; no match creates a generated-name deployment, printed (84b0656: candidates scoped app+flavor, bindings + recorded (package, instance) set + `last_attempt.requested` comparable forms, failed-first-install matches, `_direct` never a candidate and refused as the run's application, byte-cap segment truncation with named refusal when a segment cannot be a component at all).
- [x] `.version` declaration sweep: every recipe package declares its version in a one-line `.version` file (initialized `1.0.0` fleet-wide; Rachid's 2026-09-20 ruling replaces the `pkg_version()` reporter functions - packages opaque, devs trusted); result emission around package attempts, including native subjects and framework work. (results.bats 20/20)
- [x] The pass-through result stage (read idiom, return discipline, ERR-trap inhibited); line-by-line validation; the executed-code check. (results-pipeline.bats 18/18; tap wired into the stream in lib/remote.sh, payload goldens untouched; child prints `checkout v1:` once per process; full suite 719/0; gate 149/0)
- [~] Reconciliation before ordered commits (classifier buckets; membership; body order): membership + parent legitimacy + classifier landed (results-reconcile.bats 9/9; design amended lean - no recipe-text graph); the ordered commits themselves land with the dispatch worker.
- [x] Delete the runtime registry writer; split the goldens (payload half untouched; registry fixtures to migration). (writer cluster + router call removed; storage kept read-only for migration + sweep; registry-record goldens moved to tests/fixtures/legacy-registry/ as legacy samples; registry-retired.bats pins the retirement. 69/0 across registry/golden/raw-form/characterization suites)
- [x] Prove unconditional context cleanup and byte-identical payload goldens. (router wait-loop removes the dispatch context on success, failure and no-deployment alike; payload goldens byte-identical in strict compare; full suite 705/0; gate 139/0)
- [x] Slice exit: focused lock/result suites green; `task gate` green (gate 139/0, lint clean, full unit 733/0, schemas validate 0 failures; suites: worker 8/8, deployment-matching 12/12, direct-synthesis 7/7, results-pipeline 18/18, results 20/20, results-reconcile 9/9).

## 4.4 Phase-specific resolution

- [x] Gate: the reconfigure ladder insert and the `applied` source label hold Rachid's go (fragile change). (Consented 2026-09-21, ADR-030: set-scoped seeding - reconfigure resolves caller env > applied[set] > deployment > application > package > global > recipe; non-set applied values never seed; install unchanged.)
- [~] The set-scoped reconfigure ladder (ADR-030): the machinery AND the dispatch-path wiring landed (configure dispatches under an active application reference seed reconfigure at the _cloudify_dispatch_vars choke point - local, remote-payload and runbook paths; local verify seeds every applied value via _cloudify_verify_seed_env; bare commands stay unseeded). Remaining: the future runbook verify and teardown dispatches (app verify/teardown commands). (seed producer `cloudify_context_applied_seed` with the reconfigure set-filter and the verify/teardown full filter; the build seeds applied[set] before the store read - label `environment`, a set value keeps its caller identity through reseeding - and everything after it for verify/teardown - label `applied`; the post-walk check demands digest-matching resupply for literal secrets, unsupplied or mismatching dies named). Remaining: wire the seed into the live dispatch paths (configure action, local verify, the future runbook verify/teardown dispatches).
- [~] Verify and teardown seed from `applied` only (build level + local-verify wiring landed, applied-seeding.bats 5/5 + seed-wiring.bats; the app verify/teardown commands arrive later).
- [ ] The applied record and its events carry each value's resolution source (`caller` marks a set value); the comparable value objects that matching consumes carry it too.
- [ ] The applied-inputs read surface (`cloudify deployment show`) and `cloudify deployment unset <id> <NAME>` as an event-backed inventory transition.
- [x] Matching resupply for redacted literals - superseded by ADR-031 (Rachid, 2026-09-21): an unnamed run creates only the first deployment; a differing or unprovable configuration refuses naming the deployments. Not built; the fork tests became refusal tests (deployment-matching.bats 12/12).
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
