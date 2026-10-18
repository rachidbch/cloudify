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

- One resolution per dispatch - `tests/unit/context-raw-form.bats` (reads from the context alone, with every store deleted).
- Ladder order, first claim, present-but-empty is a claim - `tests/unit/vars.bats`, `tests/unit/context.bats`.
- Declaration gate, names-only mappings - `tests/unit/vars.bats`, `tests/unit/context.bats`, `tests/unit/context-wiring.bats`.
- Payload bytes, allow-list, stdin transport - `tests/unit/golden-fixtures.bats` (byte-exact), `tests/unit/remote-stdin.bats`.
- Context lifetime: 0600, path never in argv, removed on every exit - `tests/unit/context-wiring.bats`, `tests/unit/tmp-isolation.bats`, the E2E leak scenario.

## Secret classification (ADR-042)

- Marker and anchored-suffix classification, both mapping sides - `tests/unit/vars.bats`, `tests/unit/context.bats`. Names are classified; values are never inspected for secrecy.

## Shadows (docs/FRAGILE.md §2)

- Password injection, idempotency, auth - `tests/unit/shadow.bats`, `tests/unit/shadow-apt.bats`, `tests/unit/git-shadow.bats`. No literal secret reaches argv or logs.

## State and schema

- Record shape and rejected shapes - `tests/unit/state.bats`, the schema fixture matrix in `schemas/v1/validate.sh`.
- Event immutability, revision monotonicity, failure preservation - `tests/unit/worker.bats`, `tests/unit/event.bats`, `tests/unit/inventory.bats`.
- Teardown safety: reliance refusal, no teardown in a normal run - `tests/unit/uninstall.bats`, `tests/unit/deployments.bats`.

## End-to-end installs

- `tests/e2e/two-host-application.bats`: one runbook deployment across hosts, one bare dispatch recording one deployment with a binding per host, `--name` addressing it across invocations, no dispatch context left behind. The only proof recipes work on a real OS; never deleted.
