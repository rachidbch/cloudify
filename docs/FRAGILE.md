# Fragile surface

Two mechanisms fail silently and take every install with them. If a diff touches
the files below, name in the plan or commit which invariants it touches, run
`task gate`, and keep the byte-exact goldens unchanged.

## 1. Value propagation

Chain: caller env -> ladder walk (`lib/vars.sh`) -> one dispatch context
(`lib/context.sh`, 0600, swept on exit) -> payload build (`lib/remote.sh`).

- One resolution per dispatch: the registry record and the run snapshot read the
  context, never a value store again.
  Lives at `lib/context.sh` `cloudify_context_build`, `lib/registry.sh`
  `cloudify_registry_record_build`.
  Pinned by `tests/unit/context-raw-form.bats` ("no second walk", x2).
- Ladder order is weakest -> strongest (recipe default < global < package <
  application < deployment < caller env), first-write-wins via the claim ledger.
  A `KEY:` line (present-but-empty) is a claim, not an absence.
  Lives at `lib/vars.sh` `_cloudify_vars_claim`, `_cloudify_load_yaml_vars`,
  `cloudify_vars_pkg_read` (the only claimer).
  Pinned by `tests/unit/vars.bats` walker tests and
  `tests/unit/context.bats` ("rightmost package wins").
- Declaration gate: `.remote-vars` has three shapes, parsed by one enumerator
  (`cloudify_vars_declared_names`); the candidate file is three tab-separated
  fields; an application mapping feeds only declared names.
  Lives at `lib/vars.sh`, `lib/context.sh` `_ctx_candidate`.
  Pinned by `tests/unit/vars.bats`, `tests/unit/context.bats`
  ("a mapping is names only").
- Payload: the template body is literal text, extracted with `declare -f`, the
  envsubst allow-list is recovered from the context and is the only local
  substitution, values travel single-quoted, payload on stdin only.
  Lives at `lib/remote.sh` (template, allow-list recovery, stdin send).
  Pinned by `tests/unit/golden-fixtures.bats` (8 payload cases, `cmp`) and
  `tests/unit/remote-stdin.bats`.
- Context file: 0600, under `CLOUDIFY_CONTEXT_DIR`, its path never in argv,
  removed on every exit path.
  Lives at `lib/context.sh`, `lib/utils.sh` `cleanup`.
  Pinned by `tests/unit/context-wiring.bats` and the E2E leak scenario.

## 2. Shadows

`lib/shadows/{sudo,apt-get,add-apt-repository,git}.sh` + loader `lib/shadow.sh`.
Recipes call bare commands; the shadows inject passwords, idempotency and auth.
Every shadow reaches the real binary via `command` (never recursion), and the
sudo password travels on stdin (`-kS`), never argv.
Pinned by `tests/unit/shadow.bats`, `tests/unit/shadow-apt.bats`,
`tests/unit/git-shadow.bats`.

## Rules

- Editing a file above: name the invariants you touch, run `task gate`, keep the
  goldens byte-identical. A changed byte is a defect to explain, never a new
  golden to accept.
- Changing a contract (visit order, formats, ownership) or a pinning test needs
  Rachid's go first.
- Everything else in the repo is plain TDD.
