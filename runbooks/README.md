# Runbooks

Deployment procedures an agent or human executes with ONLY `ivps` and `cloudify`.
Tree: `runbooks/<app>/<flavor>.md`.

Rules:
- No ad-hoc scripts, no host commands: only `ivps` and `cloudify`.
- Variable NAMES in steps, never values.
- Addresses by MagicDNS name, never IP.
- Validate every command against the tool's own usage output (`ivps acl`, `ivps tag`,
  `cloudify ... --help`) before writing it down. Never invent a flag.
- Explicit human-gate steps; explicit teardown.

Policy rules (ivps / Tailscale ACL):
- Policy selects devices by identity only (`tag:`, `user@`, `group:`, `autogroup:`, `svc:`).
  No device names, no IPs. Two specific devices need two role tags.
- The same tag on source and destination means any-to-any; use it only for a genuine mesh.
- `ivps tag set` REPLACES a device's whole tag list; containers must keep `tag:incus` (the
  ssh rule and the lighthouse/hermes grants reference it).
- `--ssh` is for login shells; grants already allow ports. If used, always pass `--src`.
- Every policy write prints a snapshot path and a rollback command: record it, verify with
  `ivps acl show` before claiming success.
- Teardown restores policy to the pre-test state and proves it; deleting containers is not
  enough.
- A runbook the agent wrote is not an independent check of itself.

Validation: the amnesiac test. A fresh agent session, given only the cloudify skill and
the runbook path, completes the runbook on disposable infra with no human hints. Every
stumble is a runbook defect, not an agent defect.

## Engine

`cloudify deployment run <id>` executes a runbook (found by front-matter `deployment:`,
or `--runbook <path>`). Front-matter declares the deployment and its named targets; each
step is a fence whose info string types it:

    ---
    deployment: xfce-gui
    targets: guest, gateway
    ---
    ```bash step=install target=guest pkg=xfce id=install-xfce
    cloudify --on "$TARGET_GUEST" install xfce
    ```

Types: `launch|install|configure|verify|uninstall|human-gate`. Every step but `human-gate`
needs `target=`; the four package types need `pkg=` and preflight its required vars.
Targets bind with `--target name=addr`, else the deployment var `TARGET_<NAME>`.
`--dry-run` prints the plan and runs nothing.

Each run writes a 0600 snapshot in `${CLOUDIFY_DEPLOYMENTS_DIR}/<id>/runs/` (target
bindings, raw values by name, step outputs). `cloudify deployment replay <id>
[--at <run>]` re-runs one: the snapshot's bindings and values are seeded (references
resolved) and the same engine runs, so a repeated run sees the recorded values even if
the store changed. Values never appear in the runbook, in output, or on a command line.
