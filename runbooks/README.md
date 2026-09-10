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
