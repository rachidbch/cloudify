# Runbooks

Deployment procedures an agent or human executes with ONLY `ivps` and `cloudify`.

## Tree and identity

Canonical: `runbooks/<application>/<flavor>/runbook.md`.
The application identity (`<application>/<flavor>`) is derived from the path, not from the file body.
The default flavor is `default`.
Legacy: `runbooks/<application>/<flavor>.md` stays discoverable for one compatibility period.
The legacy `deployment:` front-matter field stays required only for legacy paths.
A `run` or `human-gate` step in a legacy runbook with no phase emits a deprecation warning at run time.
A canonical runbook must declare an explicit `phase=` on every `run` and `human-gate` step.

Rules:
- No ad-hoc scripts, no host commands: only `ivps` and `cloudify`.
- Variable NAMES in steps, never values.
- Addresses by MagicDNS name, never IP.
- Validate every command against the tool's own usage output (`ivps acl`, `ivps tag`, `cloudify ... --help`) before writing it down. Never invent a flag.
- Explicit human-gate steps; explicit teardown.

## Application inputs and the frozen mapping syntax

Front matter declares the application inputs and maps package variable names onto them.
The syntax is flat `key: value`, parsed with a flat reader, no YAML library:

    ---
    deployment: xfce-gui
    targets: guest, gateway
    inputs: RDP_PASSWORD
    map: CLOUDIFY_XFCE_USER_PASSWORD=RDP_PASSWORD, CLOUDIFY_GUACAMOLE_RDP_PASSWORD=RDP_PASSWORD
    ---

`inputs:` is a comma-separated list of application input names.
`map:` is a comma-separated list of `PACKAGE_VAR=APPLICATION_INPUT` pairs.
Both sides of every entry, and every declared input name, are validated against the identity rules in `schemas/v1/identity.md` (and must be a shell variable name).
A mapping whose application input is not declared is rejected before any step runs.
One application input may feed several package variables: the operator supplies `RDP_PASSWORD` once and both `CLOUDIFY_XFCE_USER_PASSWORD` and `CLOUDIFY_GUACAMOLE_RDP_PASSWORD` receive it.

## Value resolution

A mapped package variable resolves through this total order, strongest last:
recipe default < global < package < application default < mapped application input < deployment value for the package variable itself < caller environment for the package variable itself.
The application input's own value resolves in this order, strongest last:
application default < deployment value for the input name < caller environment for the input name.

Application defaults live at `apps/<application>/<flavor>/defaults.yaml` under the Cloudify configuration root, keyed by the application input name.
The `application` source label covers both the application defaults file and the mapped input.
The value is captured once, at emit time; no store is read twice, and the dispatch context file stays metadata only (names, labels, references, digests, never a plaintext value).

## Phases

The machine phase names are `install`, `reconfigure`, `verify`, `teardown`.
Default phase per step type: `launch` and `install` -> `install`; `configure` -> `reconfigure`; `verify` -> `verify`; `uninstall` -> `teardown`.
`run` and `human-gate` have no default and must declare `phase=` in a canonical runbook.
An unknown phase, or a typed step whose explicit phase contradicts its own operation, is rejected before execution.
A bare canonical run selects `install` then `verify`.
Teardown and reconfigure are explicit: `--phase teardown`, `--phase reconfigure`.
`--yes` confirms a `human-gate`; it never selects teardown.
Preflight inspects only the selected phases, so a teardown-only value cannot block an install run.
Document order is preserved inside each selected phase; phases run in the order `install`, `reconfigure`, `verify`, `teardown`.
A legacy runbook with no `--phase` keeps executing every step in document order.

## How a child dispatch gets the mapping

A runbook step body runs `cloudify ...` as a separate process.
The engine exports the resolved application input values under their declared names (so step bodies see inputs by contract) plus the names-only `CLOUDIFY_APP_MAP` (`PACKAGE_VAR=APPLICATION_INPUT,...`) and `CLOUDIFY_APPLICATION` / `CLOUDIFY_FLAVOR`.
The child dispatch reads `CLOUDIFY_APP_MAP` and resolves each mapped package variable from the input value already in its environment, recording the `application` source.
The map carries names only: no value is added to the environment beyond the input values the contract already provides, and no value travels on a command line.

## Policy rules (ivps / Tailscale ACL)

- Policy selects devices by identity only (`tag:`, `user@`, `group:`, `autogroup:`, `svc:`). No device names, no IPs. Two specific devices need two role tags.
- The same tag on source and destination means any-to-any; use it only for a genuine mesh.
- `ivps tag set` REPLACES a device's whole tag list; containers must keep `tag:incus` (the ssh rule and the lighthouse/hermes grants reference it).
- `--ssh` is for login shells; grants already allow ports. If used, always pass `--src`.
- Every policy write prints a snapshot path and a rollback command: record it, verify with `ivps acl show` before claiming success.
- Teardown restores policy to the pre-test state and proves it; deleting containers is not enough.
- A runbook the agent wrote is not an independent check of itself.

## Teardown contract

Remove exactly what the run added, in this order:

1. Software legs (`uninstall`, `unexpose`) - they need ssh and any grant alive.
2. `cloudify deployment delete <id>` - store + registry records.
3. Policy then identity: `ivps acl revoke` before `ivps tag delete` (the API rejects a tag still in use).
4. Instances: never the operator-provided ones; only those the runbook launched.

Never in the forward run: a teardown section after a `human-gate` is reachable by `deployment run --yes` (gate auto-confirmed, then teardown).
Run it with `--phase teardown` (canonical) or `--from <first-teardown-id>` and explicit `id=` on teardown steps.
Keep the ivps snapshot; prove the policy flipped (`ivps acl show`).

Validation: the amnesiac test. A fresh agent session, given only the cloudify skill and the runbook path, completes the runbook on disposable infra with no human hints. Every stumble is a runbook defect, not an agent defect.

## Engine

`cloudify deployment run <id>` executes a runbook (found by front-matter `deployment:`, or `--runbook <path>`).
Front-matter declares the deployment (legacy) and its named targets; each step is a fence whose info string types it and, for `run`/`human-gate` in a canonical runbook, names its phase:

    ```bash step=install target=guest pkg=xfce id=install-xfce
    cloudify --on "$TARGET_GUEST" install xfce
    ```

Types: `launch|install|configure|verify|uninstall|run|human-gate`. Every step but `human-gate` and `run` needs `target=`; the four package types need `pkg=` and preflight its required vars. `run` is a generic passthrough (arbitrary operator shell, e.g. `ivps expose-direct`).
Targets bind with `--target name=addr`, else the deployment var `TARGET_<NAME>`.
`--dry-run` prints the plan (including the selected phases) and runs nothing.
`cloudify_runbook_find_app <application> [<flavor>]` is the dual-discovery primitive: the canonical path first, then the legacy one.

Each run writes a 0600 snapshot in `${CLOUDIFY_DEPLOYMENTS_DIR}/<id>/runs/` (target bindings, raw values by name, step outputs).
`cloudify deployment replay <id> [--at <run>]` re-runs one: the snapshot's bindings and values are seeded (references resolved) and the same engine runs, so a repeated run sees the recorded values even if the store changed.
Values never appear in the runbook, in output, or on a command line.
