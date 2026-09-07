# Plan: C3a — Deployment-wide store + cloudify vars (ADR-011)

> ADR: ADR-011. CRITICAL GATE: subagent description → this plan → consent obtained.
> Feature branch: `feat/deployments` (from master).

## Goal

A deployment is a first-class cloud-global entity — an application across nodes.
`CLOUDIFY_DEPLOYMENT=my-cluster` in the shell provides context; `cloudify vars`
manages deployment-wide configuration; the remote payload reads deployment vars
at lowest priority (caller-env > per-pkg > deployment-wide).

## Implementation

### 1. New module: `lib/deployments.sh`

**Guard:** `_CLOUDIFY_DEPLOYMENTS_LOADED`

**Constants:**
```
CLOUDIFY_DEPLOYMENTS_DIR="${CLOUDIFY_CREDENTIALS_DIR}/deployments"
```

**Functions:**

- `_cloudify_deployment_dir <id>` → prints `$CLOUDIFY_DEPLOYMENTS_DIR/<id>`. Dies if <id> contains `/` or `..`.
- `_cloudify_deployment_config <id>` → prints `<dir>/config.yaml`
- `_cloudify_deployment_create <id>` → `mkdir -p` + init empty `config.yaml` if absent. Idempotent.
- `_cloudify_deployment_delete <id>` → `trash-put` the dir.
- `_cloudify_deployment_list` → list subdirs of `$CLOUDIFY_DEPLOYMENTS_DIR`.
- `_cloudify_deployment_read_vars <id>` → parse `config.yaml` (flat key:value YAML), export vars, return names. Same format as per-pkg yaml. Silently skip if deployment doesn't exist.
- `_cloudify_deployment_set_var <id> <key> <value>` → write/update key in `config.yaml`. Create deployment dir if needed.
- `_cloudify_deployment_delete_var <id> <key>` → remove key from `config.yaml`.
- `_cloudify_deployment_list_vars <id>` → list keys + values from `config.yaml`.

### 2. New subcommands in `cloudify` router

```
cloudify vars set <key> <value>                   set var in CLOUDIFY_DEPLOYMENT
cloudify vars set <key> --stdin                   set var from stdin (secrets)
cloudify vars set <key> --file <path>             set var from file
cloudify vars delete <key>                        delete var
cloudify vars list [--json]                       list all vars
cloudify vars show <key>                          show single var value

cloudify deployment create <id>                   create deployment
cloudify deployment delete <id>                   delete deployment (confirm)
cloudify deployment list                          list deployments
cloudify deployment use <id>                      print "export CLOUDIFY_DEPLOYMENT=<id>"
```

`vars` commands require `CLOUDIFY_DEPLOYMENT` set; error clearly if not.
`deployment` commands work without `CLOUDIFY_DEPLOYMENT` except `use` (prints hint).

### 3. Integration with `lib/remote.sh`

In `_cloudify_pkg_remote_vars()`:
- After collecting per-pkg vars and always-forward vars, if `CLOUDIFY_DEPLOYMENT` is set, read deployment-wide vars via `_cloudify_deployment_read_vars`.
- Deployment-wide vars have LOWEST priority: `_try_claim_env` / `_try_claim` already uses first-write-wins, so claiming after per-pkg and always-forward vars gives the correct precedence.
- Deployment vars are claimed AFTER per-pkg vars but BEFORE the `_CLOUDIFY_PKG_EXPORTS_` placeholder substitution. This means they appear in the exports block but lose to caller-env values.

**Precedence (final):** caller-env > per-pkg (.remote-vars names from repo) > deployment-wide > always-forward vars (CLOUDIFY_REMOTE_USER, etc.)

### 4. Debug masking

In `_cloudify_mask_secrets()` or equivalent in `cloudify` router / `lib/remote.sh`:
- Extend the existing mask pattern to include TOKEN and KEY suffixes.
- Pattern: mask values of vars whose name contains `TOKEN` or `KEY` (case-insensitive).
- This catches `K3S_TOKEN` which is currently unmasked in debug output.

### 5. .remote-vars interaction

Per-package `.remote-vars` files already declare names. Deployment-wide vars add a third source. No change to the `.remote-vars` file format.

## Non-breakage argument

**What we touch:**
1. New file `lib/deployments.sh` — additive, guarded, no existing code depends on it.
2. Router `cloudify` — add `vars` and `deployment` subcommands in the main switch. Additive; existing cases unchanged.
3. `lib/remote.sh` — add a call to `_cloudify_deployment_read_vars` in `_cloudify_pkg_remote_vars()`. The call is AFTER per-pkg claiming and BEFORE envsubst. If `CLOUDIFY_DEPLOYMENT` is unset, it's a no-op.
4. Debug masking — add TOKEN/KEY patterns to existing mask. No structural change.

**Invariants preserved:**
- `declare -f` payload extraction: unchanged. No new functions flow through the template.
- `envsubst` allow-list: unchanged. New vars are added via the same mechanism (claim → export → add to allow-list). If deployment produces no vars, the allow-list is unchanged byte-for-byte.
- First-write-wins var claiming: unchanged. Deployment vars are claimed LAST (lowest priority). If a per-pkg `.remote-vars` file or caller-env already claimed a var, the deployment claim is ignored (same as how always-forward vars behave).
- Shadow commands (`sudo`, `apt-get`, etc.): unchanged. No packages are modified.
- Subshell isolation (`pkg_depends`): unchanged. Deployment vars are read in the parent shell before the subshell, same as per-pkg vars.
- `_CLOUDIFY_PKG_EXPORTS_` placeholder: unchanged. Deployment exports are inserted into the same block via the same mechanism.

**Edge case: deployment dir doesn't exist.** `_cloudify_deployment_read_vars` silently returns if the deployment dir is absent. No error, no empty exports. This is safe — it's a no-op for the existing behavior.

**Edge case: deployment vars overlap with per-pkg vars.** First-write-wins means per-pkg wins. Intended: deployment-wide is a fallback, per-pkg is more specific.

## Testing (TDD)

### Unit tests (`tests/unit/deployments.bats`)
1. `_cloudify_deployment_dir` rejects `../` and `/`
2. `_cloudify_deployment_create` creates dir + empty config.yaml, idempotent
3. `_cloudify_deployment_set_var` writes key, updates existing, creates deployment if needed
4. `_cloudify_deployment_delete_var` removes key, no-op if absent
5. `_cloudify_deployment_list_vars` lists all keys
6. `_cloudify_deployment_read_vars` exports vars + returns names
7. `_cloudify_deployment_delete` trashes dir
8. `_cloudify_deployment_list` lists all deployment names

### Unit tests (`tests/unit/remote-vars.bats` — add new tests)
9. Deployment var forwarding: set `CLOUDIFY_DEPLOYMENT`, set var in deployment config, assert it appears in remote payload
10. Deployment vars lose to per-pkg vars (priority test)
11. No deployment set → no deployment vars forwarded (regression)

### Router unit tests (`tests/unit/packages.bats` or new)
12. `cloudify vars set/delete/list` with valid/invalid CLOUDIFY_DEPLOYMENT
13. `cloudify vars set --stdin/--file`
14. `cloudify deployment create/list/delete/use`

## Done gate

- All unit tests green
- `task lint` green
- `task test-unit` green
- HISTORY.md + ADR.md updated
- Deployed to remote-vars (C1) validations: deployment vars appear in remote payload at correct priority
