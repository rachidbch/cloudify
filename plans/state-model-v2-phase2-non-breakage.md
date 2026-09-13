# Phase 2 repair: non-breakage argument

Precondition 2 of the project CRITICAL GATE. Read with
`plans/state-model-v2-forwarding-description.md` (the description artifact) and
`plans/state-model-v2-recovery.md` R1.

Status: written 2026-09-13, before the first `lib/` edit. Consent not yet given.

## 1. The change in one paragraph

Today the dispatch context is a metadata-only file, so the registry record and
the run snapshot cannot recover a value's raw text from it, and
`_cloudify_registry_context_raw` (`lib/registry.sh:260-278`) reopens the value
stores to get that text back. That is a second walk: the store can change between
the payload's resolution and the record's, and an absent value is
indistinguishable from a present-but-empty one. The fix makes
`cloudify_context_build` carry, for every declared name of the top-level package
and every dependency that may execute, the resolved runtime form plus its
provenance (declaration, source label, source form, reference, secret flag,
digest). The registry record, the snapshot and all later writers then read that
one context. `_cloudify_registry_context_raw` and every equivalent store re-opener
are deleted.

## 2. Files in scope

- `lib/context.sh` - `cloudify_context_build` and its write block only.
- `lib/registry.sh` - delete `_cloudify_registry_context_raw`; point
  `cloudify_registry_record_build` at the context.
- `lib/vars.sh` - capture the raw text at the single export decision in
  `_cloudify_vars_emit`, next to the provenance label it already records.
- `lib/remote.sh` - `_cloudify_dispatch_vars` (`lib/remote.sh:116-142`) **name
  extraction only**. Today the allow-list is recovered from the flat context with
  `sed -n 's/^value\.\([^.]*\)\.source:.*$/\1/p' "$CLOUDIFY_CONTEXT_FILE"`
  (`lib/remote.sh:127`). Once the context is JSON that sed matches nothing, the
  allow-list goes empty and payload forwarding silently stops exporting package
  values. The extraction changes; the payload template (`lib/remote.sh:24-77`),
  the single `envsubst` call (`:221-242`) and the stdin transport (`:270-274`) do
  not.
- `lib/runbooks.sh` - the snapshot's resolver (`_cloudify_runbook_resolver_value`
  invoked from the seed block around `lib/runbooks.sh:1390`) still re-reads the
  deployment, package and global stores through `_cloudify_vars_store_get`. It
  must read the context instead, which is what R1.2 already requires.
- `lib/utils.sh` and `cloudify` - the single-owner context epilogue described in
  section 4.

Not in scope: the payload template, the `envsubst` invocation, the stdin
transport, `lib/shadows/*`, `lib/shadow.sh`, `pkg/*`, and the value-resolution
ladder itself.

## 3. Why forwarding cannot break

Each claim names the code that would have to change for it to fail.

1. **The payload is still literal text plus one envsubst pass.**
   `cloudify_remote_payload_template` (`lib/remote.sh:24-77`) and the single
   `envsubst` invocation (`lib/remote.sh:241-242`) are untouched. The context is
   read *before* the template is rendered, never during it. Would break if the
   allow-list were rebuilt from context keys instead of staying an explicit list.

2. **The allow-list still gates local substitution.** The list stays the same
   set of names. `$HOME` and `$(...)` still resolve on the remote side. Re-asserted
   by the byte-exact payload goldens (`tests/fixtures/golden/payload/*`, 8 cases)
   compared with `cmp` by `tests/unit/golden-fixtures.bats`.

3. **Values still reach the remote as single-quoted exports.** Nothing about how
   a resolved value is quoted or exported changes; only where the record reads it
   from. Would break if a value were re-resolved after the template was built.

4. **The context path still never reaches argv.** It remains a variable and the
   payload still travels on stdin (`lib/remote.sh:271-274`). The context file
   gains fields; its handling does not change.

5. **The single export decision stays single.** `_cloudify_vars_emit`
   (`lib/vars.sh:163-196`) stays the only place that decides both the exported
   value and its label. The change adds a capture beside the existing one; it does
   not add a second pass, and it does not read a store again.

6. **First-write-wins order is untouched.** The ladder stays recipe < global <
   package < application < deployment < caller environment
   (`lib/vars.sh:56-66`). Claiming still precedes the emptiness check
   (`lib/vars.sh:169`), so a present-but-empty store value still
   wins rather than falling through.

7. **The record and the payload cannot disagree.** They now consume the same
   context by construction, which is strictly stronger than today's shared-label
   agreement. Re-asserted by `tests/red/state-v2-duplicate-resolution.bats` and the
   9 registry goldens.

8. **Secrets still do not leak.** The context file is 0600 and ephemeral. It may
   hold resolved plaintext because the target process needs it (`REDESIGN.md:302`),
   and plaintext remains forbidden in logs, manifests, package state, run records,
   events and debug output.

   **The current removal is not single-owner, and R1 must fix that before it puts
   plaintext in the file.** Two live leak paths exist today:
   `_cloudify_registry_record_bg` returns early when `CLOUDIFY_DEPLOYMENT` is
   unset (`lib/registry.sh:395-397`), which is the direct package command path, and
   never reaches its `rm -f "$context"` (`lib/registry.sh:415-417`); and the only
   backstop, `cleanup()` (`lib/utils.sh:74-87`), returns early under
   `CLOUDIFY_LOG_LEVEL=DEBUG` (`lib/utils.sh:77-79`). So a successful
   `cloudify --on host install pkg` with DEBUG on leaves a plaintext file behind.
   R1 therefore owns the fix: one EXIT and RETURN trap armed at context creation,
   removing the file on success, failure and interruption, plus a test proving no
   context file survives all three. Phase 4.3 inherits that owner and only has to
   keep it working when the registry writer is deleted.

9. **The shadows are unaffected.** Nothing in scope reads or writes
   `lib/shadows/*` or `lib/shadow.sh`, and no command they override changes
   signature or behaviour.

10. **The CLI surface is unchanged.** No verb, flag or output format changes in
    this slice.

## 4. The one new risk, and its mitigation

The context file now carries resolved plaintext where it previously carried only
metadata. That is the redesign's intent (`REDESIGN.md:208`, `:302`, `:213`), and it
is the reason the file is 0600, created by the parent, never named in argv, and
removed by the parent on success, failure and interruption. Today's removal is not
single-owner (section 3, item 8), so R1 must first install one owner: an EXIT and
RETURN trap armed when the parent creates the context, covering both the direct
package command path and the DEBUG path. The mitigation is threefold: one owner
for removal, a test proving no context file survives a successful, a failed and an
interrupted dispatch, and a scan proving no fixture secret appears in any log,
manifest, state, run or event.

## 5. What was traced, not assumed

- The payload write block and the single `envsubst` call, to confirm the context
  is not consulted during rendering.
- `_cloudify_vars_emit` and `_cloudify_vars_sources_record`, to confirm one export
  decision already exists and can carry the raw text without a new pass.
- `_cloudify_registry_context_raw` and its caller, to confirm the second walk is
  the only reason the raw text is recovered twice.
- The context removal paths (`lib/registry.sh:415-417`, `cloudify:822-824`,
  `lib/remote.sh:212-215`), to confirm one of them must be replaced, not merely
  deleted, before the registry writer goes.

## 6. Falsification: how to detect a break

Run in this order. A failure at any step stops the slice.

1. `bash schemas/v1/validate.sh` - the new context schema and its fixtures.
2. `tests/unit/golden-fixtures.bats` - payload and registry bytes unchanged.
3. `tests/unit/context-wiring.bats`, `tests/unit/vars.bats`,
   `tests/unit/remote-vars.bats`, `tests/unit/remote.bats`.
4. `tests/red/state-v2-duplicate-resolution.bats` plus
   `tests/unit/state-v2-characterization.bats`.
5. The new mutation proof: build a context, then delete or mutate every source
   file, and confirm payload, record and snapshot still answer from the context.
6. `tests/unit/drivers/context.bats` - L1, real target, no dispatch.
7. `task lint`, then the full unit suite.

## 7. Verdict

The change moves where a fact is read, not how a value travels. Every invariant
listed in the description artifact is either untouched or re-asserted by an
existing byte-exact test. The only genuinely new exposure is plaintext in a 0600
ephemeral file that the redesign already requires, and it is covered by an owner,
a removal test and a leak scan.

Requested: Rachid's explicit consent to edit `lib/context.sh`, `lib/registry.sh`
and `lib/vars.sh` for this scope only.
