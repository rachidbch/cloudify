# Runbooks

Deployment procedures an agent or human executes with ONLY `ivps` and `cloudify`.
Tree: `runbooks/<app>/<flavor>.md`.

Rules:
- No ad-hoc scripts, no host commands: only `ivps` and `cloudify`.
- Variable NAMES in steps, never values.
- Addresses by MagicDNS name, never IP.
- Explicit human-gate steps; explicit teardown.

Validation: the amnesiac test. A fresh agent session, given only the cloudify skill and
the runbook path, completes the runbook on disposable infra with no human hints. Every
stumble is a runbook defect, not an agent defect.
