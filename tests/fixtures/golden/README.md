# Golden fixtures

Byte-exact captures of two formats, pinned as data so they survive without the
code that first produced them.

- `payload/<case>.txt` - the remote dispatch payload text, exactly as it reaches
  `ssh ... bash -s` on stdin.
- `registry/<case>.yaml` - the registry record text, exactly as
  `cloudify_registry_record_build` prints it, with only the three write
  timestamps (`installed_at`, `configured_at`, `removed_at`) normalised to
  `<ts>`.

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
stdin (never argv), and `cloudify_registry_record_build` with a real dispatch
context built by `cloudify_context_build`. The payload capture pins
`CLOUDIFY_LOG_FILE` so the forwarded `CLOUDIFY_LOG_BASENAME` carries no
timestamp.

## What a diff means

A diff here means the payload text or the registry record format changed. That
is a deliberate act, not an accident: look at the diff, decide whether the
change is intended, and only then re-capture with `GOLDEN_CAPTURE=1`. Never
re-capture to make a red test green.
