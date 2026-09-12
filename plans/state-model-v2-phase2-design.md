# State model v2 - Phase 2 interface design

Pinned before any Phase 2 code, so the implementation is reviewable and the
75+ recipes keep working. Gates: `plans/state-model-v2.md` G1, G2, G3 (Phase 2
consent recorded in `LOGS.md`). Evidence base: `plans/state-model-v2-description.md`
(invariant numbers below are its section 8) and
`plans/state-model-v2-non-breakage.md` section 3.

## 1. Goal and the one behavior change

Goal: one dispatch resolves a declared name once, and the payload, the registry
record and the run snapshot all come from that one resolution.
Today the payload comes from `_cloudify_pkg_remote_vars` (inv 4), the registry
record from `_cloudify_registry_raw_var` (inv 18, a second implementation that
can disagree), and the snapshot `value.*` lines from the deployment store alone.
The one behavior change Phase 2 accepts is that the registry record and the
snapshot now report the same first-providing source as the payload. For any
dispatch where those three already agreed, output must stay byte-identical.

## 2. Slices

- 2A: new `lib/context.sh` (resolver + context file), additive, nothing wired. Zero blast radius.
- 2B: wire it: payload from the context, registry writer from the context, snapshot and preflight from the resolver, retire `_cloudify_registry_raw_var`, legacy switch.
- 2C: gate: unit suite, L1 driver on the container, L2/L3 on one harmless fixture package, `task lint`, rollback note.

## 3. Module and interface

New module `lib/context.sh`, guard `_CLOUDIFY_CONTEXT_LOADED`, sourced by the
router after `lib/vars.sh` and `lib/registry.sh`. It owns resolution only: it
reads sources through the existing `lib/vars.sh` readers, it never builds a
payload and never writes a record.

`cloudify_context_build <action> <deployment> <phase> <declared-names-file> <packages...>`
- Runs in the dispatch shell, exports every resolved runtime literal into that shell (inv 1), and never emits a value on stdout.
- Writes the context file to `$CLOUDIFY_CONTEXT_FILE` (created by the caller, mode 0600) and prints nothing else.
- `<declared-names-file>` is the candidate name set: the union of `.remote-vars` names for the top-level package and every dependency the graph walk finds (inv 29 today, expanded by the static graph walk).
- Resolution order is the existing ladder, unchanged: deployment, then packages rightmost-CLI-first with dependencies, then global, then caller env, with first-write-wins and caller env never overwritten (inv 4).
- `<phase>` is accepted and recorded now, and selects nothing in Phase 2.

`cloudify_context_source_of <name> <pkg>` (pure, non-mutating)
- Returns one label: `environment`, `deployment`, `package`, `global`, or `recipe`.
- Never exports, never writes, never resolves the raw value.
- `_cloudify_vars_source_of` and runbook preflight are reimplemented over this function, so preflight and dispatch cannot select different sources.

`cloudify_context_read <context-file> <field>` (parent side read surface)
- Prints one field of the context file. Used by the registry writer.

## 4. Context file (metadata only, never a value)

Flat `KEY: value` lines, mode 0600, under `CLOUDIFY_TMP`, one per dispatch.
Required fields: `context_version: 1`, `action`, `deployment`, `phase`, `target`
(the resolved `node\tinstance\tssh_host` triple), `top_kind` (`package` or
`verified`).
Per resolved name, one `value.<NAME>` block with these sub-fields:
`source` (the label from section 3), `form` (`literal` or `reference`),
`secret` (`true`/`false`, from the explicit declaration metadata when present
and from the existing name heuristic as defense in depth), `reference` (the
`@backend:locator` text when `form` is `reference`), `digest` (the literal-secret
digest when `form` is `literal` and `secret` is true).
No plaintext value, no resolved value, and no payload text ever appears in the
context file. That is the invariant that keeps 2.1's "compute digests without
persisting plaintext" honest, and it is asserted by a test that greps every
context file for the fixture secret.

## 5. How the parent learns the context path

The parent (router or `cloudify_remote`) creates the file with `mktemp` and
exports `CLOUDIFY_CONTEXT_FILE` before starting the child, so the path never
travels as an argument and never enters ssh argv (G2 3.2, inv 2).
The child (the per-host `cloudify_remote_sync` subshell, or the backgrounded
local install subshell) fills it.
The registry writer in the parent reads it via the existing per-pid metadata
(`_cloudify_note_bg`, `_CLOUDIFY_BG_*`), extended with the context path.
Cleanup: the parent removes the file after the registry write, and on the
failure path; a missing or unreadable context file means no record is written
with a warning, never a fallback to a second walk.

## 6. Compatibility rules that make this safe

1. Recipes are untouched: the same names are exported into the same shell with the same values for every existing dispatch shape (inv 1, 4, 5, 6, 7, 8, 12, 13).
2. The payload text stays byte-identical except that its name list now comes from the context: same fixed 25-token allow-list, same `export NAME='$NAME'` rendering, same single quotes, same stdin transport, same per-command `< /dev/null` (G2 3.2, 3.3, 3.4).
3. The registry record stays byte-identical for every case where the old and new walks agreed. The proof is an equivalence test: build the record with `_cloudify_registry_raw_var` and with the context for a fixture matrix (caller env only, deployment only, package only, global only, secret reference, multiline `@base64:`, undeclared ambient name) and assert the two record texts are equal. The old function is deleted only after that test is green.
4. The snapshot keeps every deployment-store key and adds or corrects only the declared names the context knows, so no line is dropped for existing deployments.
5. Direct package commands, verify, and the legacy single-ID deployment store keep their Phase 1 behavior; the only difference is that the record and the snapshot now agree with the payload.
6. Shadows are untouched (`lib/shadows/`, `lib/shadow.sh`), pinned by the sha256 check from G2 3.6.
7. Rollback: `CLOUDIFY_LEGACY_VARS=1` restores `_cloudify_pkg_remote_vars` as the payload's name source and `_cloudify_registry_raw_var` as the record's value source. Both functions stay in the tree until Phase 8, behind that switch, so a rollback needs no data transformation.

## 7. What Phase 2 must not do

- Not touch verify's own yaml load (`_cloudify_run_verify`, G2 6.1) and not change what a remote verify forwards (inv 33).
- Not add locks, claims, package state, events, or any new on-disk state under the state root (Phases 3, 4, 6).
- Not add a remote result channel (G2 6.2, Phase 4).
- Not fix the pre-existing hazards in G2 6.4: allow-list name collision, single-quote injection, the inert depth increment, and the static-walk blind spots beyond what the graph walk needs.
- Not change the target grammar or ivps reads.

## 8. Test matrix for 2B

Red first: `tests/red/state-v2-duplicate-resolution.bats` test 1 must go green
(payload, registry and snapshot agree). Test 2 stays red until Phase 3, which
introduces application input mappings.
Then: the equivalence test of section 6.3; the existing `vars`, `remote-vars`,
`remote`, `remote-stdin`, `registry`, `registry-write`, `runbook-exec`,
`runbook-replay` suites; a context-file secret grep; and the Phase 2C gate.
