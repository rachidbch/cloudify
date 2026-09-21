# Golden fixtures

Byte-exact captures of one format, pinned as data so they survive without the
code that first produced them.

- `payload/<case>.txt` - the remote dispatch payload text, exactly as it reaches
  `ssh ... bash -s` on stdin.

The cases are the fixture matrices the retired equivalence tests used:
`tests/unit/golden-fixtures.bats` rebuilds every case from the surviving v2 path
and compares byte for byte with `cmp`.

## How they were captured

Before `_cloudify_pkg_remote_vars` and `_cloudify_registry_raw_var` were deleted,
`bats tests/unit/context-wiring.bats tests/unit/registry-write.bats` passed: its
equivalence tests built the payload and the record twice, once through the
legacy walkers and once through the dispatch context, and asserted byte
equality. Those runs are the provenance of these fixtures - the context path
captured here is the same text the legacy path produced.

Capture command (container `cloudai:cloudify`, on the branch where the fixtures
did not exist yet):

    GOLDEN_CAPTURE=1 bats tests/unit/golden-fixtures.bats

Run `cloudify_remote_sync` through a stubbed `ssh` that reads the payload from
stdin (never argv). The payload capture pins `CLOUDIFY_LOG_FILE` so the
forwarded `CLOUDIFY_LOG_BASENAME` carries no timestamp.

## What a diff means

A diff here means the payload text changed. That is a deliberate act, not an
accident: look at the diff, decide whether the change is intended, and only
then re-capture with `GOLDEN_CAPTURE=1`. Never re-capture to make a red test
green.

## The legacy registry records

The former `golden/registry/<case>.yaml` samples moved to
`tests/fixtures/legacy-registry/` when the runtime registry writer was retired
(state-model-v2 4.3, 2026-09-20). They are not pinned against code anymore -
there is no code that produces this format. They are reference samples of the
legacy record format for `cloudify state migrate-registry` (4.7): each file is
one old record exactly as the retired writer produced it, with only the three
write timestamps (`installed_at`, `configured_at`, `removed_at`) normalised to
`<ts>`.
