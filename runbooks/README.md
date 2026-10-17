# Runbooks

Deployment procedures an agent or human executes with ONLY `ivps` and `cloudify`.

## Tree and identity

Canonical: `runbooks/<application>/<flavor>/runbook.md`. It is the only discoverable runbook path: exactly two levels under the runbooks root, so a deeper `runbook.md` is not canonical and carries no application identity.
The application identity (`<application>/<flavor>`) is derived from the path, not from the file body.
The default flavor is `default`.
A flavor is a structural variant of a runbook, such as a single-host plan versus a split-host plan; it is not the name of one running deployment.
For example, `xfce-guacamole/default` selects a reusable plan, while `--name work-desktop` identifies one deployment of that plan.
Another deployment of the same plan has its own name, hosts, and inputs.
A `run` or `human-gate` step must declare an explicit `phase=`.
REMOVED (2026-09-29): the `deployment:` front-matter field and its `CLOUDIFY_DEPLOYMENT` fallback are gone - a runbook carrying the field is refused named. Identity derives from the runbook path plus the deployment name (`--name`), and runs identify by timestamp under the deployment's state-tree runs dir (`~/.local/state/cloudify/deployments/<app>/<flavor>/<name>/runs/<utc>.yaml`).

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
    targets: guest, gateway
    inputs: secret RDP_PASSWORD
    map: CLOUDIFY_XFCE_USER_PASSWORD=RDP_PASSWORD, CLOUDIFY_GUACAMOLE_RDP_PASSWORD=RDP_PASSWORD
    ---

`inputs:` is a comma-separated list of names or `secret NAME` entries.
A marker needs its name before the next comma; duplicate declarations keep their first position and any secret annotation wins.
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
The value is captured once, at emit time; no store is read twice.
The private dispatch context may hold resolved plaintext for execution and is removed after the dispatch.
Classification uses `secret NAME` markers in package `.remote-vars` and runbook `inputs:`, plus exact uppercase endings `_PASSWORD`, `_SECRET`, `_TOKEN`, `_KEY`, `_PWD` (Secret markers with suffixes, ADR-042).
Either qualifying mapping side makes the input and its aliases secret; the sweep replaces substring guessing but does not remove the suffix safety net.
Complete removal of name-based recognition is deferred to ROADMAP.md.
The input-name API still returns bare names, without annotations.
Legacy reference classification, secret-demand preflight, and unsafe snapshots remain until their separate implementation slices; this marker sweep does not make old snapshots safe.
Do not assume an input's origin in secretspec supplies Cloudify with classification or a persistent secret location.

## Application commands and the deployment manifest

`cloudify app run <application>[/<flavor>] [--name <name>]` is the application surface.
The flavor defaults to `default`.
Current code also selects a deployment literally named `default` when `--name` is omitted.
That differs from the accepted matching/name-generation rule in Named second deployments (ADR-031); the mismatch is tracked under inventory-only recovery in ROADMAP.md.
Use an explicit semantic name such as `--name work-desktop` while it remains unresolved.
It prints the full reference (`Application: k3s/default`) and the deployment name in every plan and error, exports `CLOUDIFY_APPLICATION`, `CLOUDIFY_FLAVOR` and `CLOUDIFY_DEPLOYMENT_NAME` for the child dispatches, and then runs the runbook (bare run: install then verify; teardown is never selected).
A three-segment reference (`a/b/c`) is rejected rather than guessed.
`cloudify deployment replay <id>` re-runs a recorded run through the same engine.
`app reconfigure`, `app verify` and `app teardown` are reserved until Phase 4 has physical package state and claims, and say so.

Applied package facts live in Cloudify's inventory under the ivps node and instance directories.
The manifest at `<state-root>/deployments/<application>/<flavor>/<deployment>/manifest.json` is a current-state read cache, where `<state-root>` is `${XDG_STATE_HOME:-$HOME/.local/state}/cloudify`.
`cloudify deployment show <application>[/<flavor>] --name <name>` prints the manifest and the run snapshots.
`cloudify deployment list` lists current manifests.
The plural `cloudify deployments` spelling in the intended read surface is not implemented.

A local per-deployment file lock protects manifest writes.
The manifest holds identity, application commit, development override, lifecycle status, creation time, target bindings, and the last run and event IDs.
It never holds applied package values.
Status is derived from observed events: `adopted`, `installed`, `reconfigured`, `verified`, or `degraded`; an unproved manifest starts with null status.
An install whose verification stage fails can remain `installed`, with the failed check recorded in health.
Inventory owns current state (ADR-036) requires using a valid cache or rebuilding it from inventory without requiring history.
Current code instead provides an explicit event-based rebuild and does not fully meet that requirement; this is a recorded compliance bug, with implementation queued after specification convergence.

Current code records target bindings in the manifest and reuses them rather than re-prompting.
Inventory owns current state (ADR-036) also requires those bindings to be recoverable from inventory; a missing manifest must not lose them.
The implementation still needs that repair.
A caller-supplied `--target` that differs is a rebinding and needs `--migrate-targets`, because rebinding is a migration, not a rerun. Once a deployment has active claims (Phase 4) a rebinding fails closed.

The manifest records the Cloudify commit of the runbook and recipes in use.
A dirty or unidentified tree is refused unless `CLOUDIFY_DEVELOPMENT_OVERRIDE=1` is set; the run is then recorded with `development_override: true` and is never labelled replayable.

## Desired inputs: the nested path, and the one-shot migration

Desired inputs live at `<config-root>/deployments/<application>/<flavor>/<deployment>/values.yaml` (0700 directories, 0600 files), flat `KEY: value` like every other store.
It is the only desired-inputs store: a read and a write both resolve it from the active application reference (`CLOUDIFY_APPLICATION`, `CLOUDIFY_FLAVOR`, `CLOUDIFY_DEPLOYMENT_NAME`, which `cloudify app run` exports).
Without an application reference there is no deployment source: `cloudify vars set --deployment <id>` fails closed and names the application command, and the dispatch ladder forwards no deployment value.

`cloudify deployment migrate <id> --application <app> [--flavor <flavor>] [--name <name>] [--dry-run] [--force]` is a temporary one-shot bridge, deleted once the existing stores are moved: it is the only reader of the old single-ID store `<config-root>/deployments/<id>/config.yaml` and copies it once into the nested path.
It prints an inventory-only report (names and paths, never a value) and a merge plan (`add`/`conflict`, names only), so `--dry-run` shows exactly what would change.
The deployment ID is never split to guess the tuple: application and flavor must be stated.
The copy is idempotent (a key already present with the same value is a no-op) and never deletes a key or the single-ID store.
A key the destination holds with a different value is refused unless `--force`.

## Phases

The machine phase names are `install`, `reconfigure`, `verify`, `teardown`.
Default phase per step type: `launch` and `install` -> `install`; `configure` -> `reconfigure`; `verify` -> `verify`; `uninstall` -> `teardown`.
`run` and `human-gate` have no default and must declare `phase=`.
An unknown phase, or a typed step whose explicit phase contradicts its own operation, is rejected before execution.
A bare run selects `install` then `verify`.
Teardown and reconfigure are explicit: `--phase teardown`, `--phase reconfigure`.
`--yes` confirms a `human-gate`; it never selects teardown.
Preflight inspects only the selected phases, so a teardown-only value cannot block an install run.
Document order is preserved inside each selected phase; phases run in the order `install`, `reconfigure`, `verify`, `teardown`.

## How a child dispatch gets the mapping

A runbook step body runs `cloudify ...` as a separate process.
The engine exports resolved input values under their declared names, the names-only `CLOUDIFY_APP_MAP` (`PACKAGE_VAR=APPLICATION_INPUT,...`), and `CLOUDIFY_APPLICATION` / `CLOUDIFY_FLAVOR`.
`CLOUDIFY_APP_SECRET_INPUTS` separately carries explicitly secret input names, including names protected through a package-side marker; each spec export resets it.
The child resolves each declared package alias from the input already in its environment, recording the `application` source, and propagates marker/suffix classification through all connected aliases.
Classification metadata never claims a value, adds a payload export, or changes the map format.
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
2. The observation records: `cloudify_registry_delete_deployment <id>` sweeps the node and instance buckets once application teardown removes the store (Phase 7).
3. Policy then identity: `ivps acl revoke` before `ivps tag delete` (the API rejects a tag still in use).
4. Instances: never the operator-provided ones; only those the runbook launched.

Never in the forward run: a teardown section after a `human-gate` is reachable by `app run --yes` (gate auto-confirmed, then teardown).
Run it with `--phase teardown` (canonical) or `--from <first-teardown-id>` and explicit `id=` on teardown steps.
Keep the ivps snapshot; prove the policy flipped (`ivps acl show`).

Validation: the amnesiac test. A fresh agent session, given only the cloudify skill and the runbook path, completes the runbook on disposable infra with no human hints. Every stumble is a runbook defect, not an agent defect.

## Engine

`cloudify app run <application>[/<flavor>] [--name <name>]` executes the application's canonical runbook.
The lower-level `cloudify_deployment_run` engine takes `--runbook <path>`, which `cloudify deployment replay` uses to re-run a recorded runbook outside the tree.
Front-matter declares the named targets; each step is a fence whose info string types it and names its phase for `run`/`human-gate`:

    ```bash step=install target=guest pkg=xfce id=install-xfce
    cloudify --on "$TARGET_GUEST" install xfce
    ```

Types: `launch|install|configure|verify|uninstall|run|human-gate`. Every step but `human-gate` and `run` needs `target=`; the four package types need `pkg=` and preflight its required vars. `run` is a generic passthrough (arbitrary operator shell, e.g. `ivps expose-direct`).
Targets bind with `--target name=addr`, else the deployment var `TARGET_<NAME>`.
A single-target runbook still declares its name, for example `targets: server`, and the operator supplies `--target server=cloudstation:guac-gui`.
There is no implicit target name or implicit localhost binding.
Targetless canonical applications are not supported by the current manifest contract, even though the lower-level parser accepts targetless `run` and `human-gate` steps.
`--dry-run` prints the plan (including the selected phases) and runs nothing (and creates no manifest).
A canonical runbook also writes the deployment manifest; a path outside the tree carries no identity and writes no manifest.

Each run writes a 0600 snapshot in the deployment's state-tree runs dir (`~/.local/state/cloudify/deployments/<app>/<flavor>/<name>/runs/<utc>.yaml`) - target bindings, raw values by name, step outputs.
**Security warning:** current snapshots can contain plaintext secrets and unclassified step outputs.
Mode 0600 restricts readers but does not encrypt the file.
Keep snapshots out of Git, shared directories, and unencrypted backups; current snapshots are not safe publication artifacts.
`cloudify deployment replay <application>[/<flavor>] --name <name> [--at <run>]` seeds bindings and values from the selected snapshot and executes the same engine.
Secrets enter through the environment (ADR-037) replaces the provider-aware replay proposal: future safe snapshots record secret names only and replay requires the caller to supply their values again.
Validate after application mappings so an input such as `RDP_PASSWORD` can supply both package aliases.
Do not overwrite those environment values with historical literals or load secret values from current inventory.
Missing required supply must fail before mutation; the optional-secret rule and exact marker format remain to be settled.
Safe snapshots and environment-only replay are tracked in ROADMAP.md; current code still needs the repair.
Values never appear in the runbook or on the Cloudify command line.
