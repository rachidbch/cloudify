# Test sanctuary

Tests listed here guard behaviors that fail silently and take real installs
with them. They are never deleted as bloat, and the selector must always
include them when their surface appears in a diff. Everything outside this list
is subject to pruning: a test that freezes behavior no caller depends on, or
duplicates another guard, can go.

Rule for the working agent: you may add tests here only with a stated reason
(which failure the guard prevents and how it fails when the behavior breaks).
Removing an entry, or weakening its guard into a smoke check, needs Rachid's
explicit decision - same weight as changing a contract.

Each entry names the surface, the guard file, and what the guard actually
proves. An entry whose guard only asserts "does not crash" is not a guard and
must be strengthened before the entry is trusted.

## Value propagation (docs/FRAGILE.md §1)

- One resolution per dispatch - `tests/unit/context-raw-form.bats`. Proves the
  context is the only source (reads succeed with every store deleted or changed).
- Ladder order and first-claim semantics - `tests/unit/vars.bats`,
  `tests/unit/context.bats`. Proves weakest->strongest, rightmost package wins,
  and a present-but-empty line is a claim.
- Declaration gate (`.remote-vars` shapes, names-only mappings) -
  `tests/unit/vars.bats`, `tests/unit/context.bats`, `tests/unit/context-wiring.bats`.
- Payload bytes, allow-list, stdin transport - `tests/unit/golden-fixtures.bats`
  (byte-exact) and `tests/unit/remote-stdin.bats`. A change here without a golden
  diff review is a defect, not a test update.
- Context lifetime: 0600, path never in argv, removed on every exit path -
  `tests/unit/context-wiring.bats`, `tests/unit/tmp-isolation.bats`, plus the
  E2E leak scenario in `tests/e2e/two-host-application.bats`.

## Secret classification (docs/FRAGILE.md, ADR-042)

- Marker and anchored-suffix classification, both mapping sides, shared input
  protection - `tests/unit/vars.bats` (suffix boundaries, fan-out) and
  `tests/unit/context.bats`. The direction is one-way: names are classified,
  values are never inspected for secrecy.

## Shadows (docs/FRAGILE.md §2)

- Password injection, idempotency and auth shims - `tests/unit/shadow.bats`,
  `tests/unit/shadow-apt.bats`, `tests/unit/git-shadow.bats`. Proves the wrapper
  is transparent to the recipe and that no literal secret reaches argv or logs.

## State and schema contracts

- Lean record shape, required fields, rejected shapes -
  `tests/unit/state.bats` plus the schema fixture matrix run by
  `schemas/v1/validate.sh` (valid fixtures must be accepted, invalid ones
  rejected; a fixture that disagrees with its schema is the failure).
- Event immutability, revision monotonicity, failure preservation -
  `tests/unit/worker.bats`, `tests/unit/event.bats`, `tests/unit/inventory.bats`.
- Record/destination paths and identity validation -
  `tests/unit/state.bats`, `tests/unit/inventory.bats`.
- Teardown safety: reliance refusal, no normal run executes teardown -
  `tests/unit/uninstall.bats`, `tests/unit/deployments.bats`.

## End-to-end installs

- The real install path on real machines - `tests/e2e/two-host-application.bats`.
  Proves: one runbook deployment across several hosts, one bare dispatch across
  hosts recording one deployment with a binding per host, `--name` addressing a
  direct deployment across invocations, and that no dispatch context survives.
  It is the only test that proves recipes work against a real OS, so it is never
  deleted; it is run when package, transport or dispatch behavior changes.
