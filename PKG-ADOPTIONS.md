# PKG-ADOPTIONS - taking the existing fleet into the deployment model

Census of 2026-09-23 (ivps instances, read-only scans). The legacy registry is empty of real data, so every existing installation is the fog case: adoption, operator-driven.

The flow per entry (agreed with Rachid):

1. Machine investigation (read-only): unit environments, docker inspect, config files.
2. Value table presented: recorded/effective values + confidence flags (`heuristic`, `stale?`, `unknown`).
3. Rachid corrects the wrong values.
4. Deployment shape proposed (name, application/flavor, packages).
5. Disciplined write: guarded `--adopt` (or event-first write), inventory only after a successful configure.

## Adoption queue

- [ ] `cloudai:hermes` - the full Hermes stack.
  Findings: docker `open-webui` (ghcr.io/open-webui/open-webui:main); systemd units `hermes-dashboard.service`, `ollama.service`, `open-webui.service`, `owui-webhook-ntfy.service`.
  Recipe mapping: `hermes` + `hermes-dashboard` + `hermes-openwebui` (+ ollama handling to verify).
  Status: awaiting round two (value investigation).
- [ ] `cloudai:hermes-svc` - partial Hermes family.
  Findings: docker `open-webui`; unit `open-webui.service`.
  Recipe mapping: open-webui part of the hermes family; verify what else lives there.
  Status: awaiting round two.
- [ ] `cloudai:openwebui-hermes` - standalone open-webui.
  Findings: docker `open-webui`; unit `open-webui.service`, plus `sshd.service`.
  Recipe mapping: `open-webui`.
  Status: awaiting round two.
- [ ] `cloudai:affine` - IN PROGRESS (the pilot adoption).
  Investigation complete: deployed by cloudify from our repo (clone + remote + init cookie on the instance); the service RUNS (node 24, listening :8787, live state.db, master token already stored offline by Rachid). The census missed it because it is a systemd USER unit, not system-level.
  Applied values: all recipe defaults (port 8787, dir ~/PROJECTS/affine); no user-supplied values ever (no store file, no declaration before now). Server config surface verified from source: AFFINE_PORT, AFFINE_RATE_LIMIT, AFFINE_RATE_WINDOW_MS, AFFINE_DB (env) + optional .linear-api-key file (compatibility key: clients bearing the real Linear key get an anonymous context; file ABSENT on this machine).
  Rulings so far: record observed effective values as recipe-sourced; backup is EXTERNAL (S3, another agent) - cloudify only writes the contract (what + watch-fors, in pkg/affine/README.md); deployment shape is a first-class application runbook (affine/default/main), not _direct.
  Done: pkg upgraded (split install/configure, all knobs declared, secret marker for the key, v1.1.0); runbooks/affine/default/runbook.md written.
  Remaining: prove configure on the machine (L2/L3), external backup per the README contract, manual event-first adoption write (affine/default/main, version 1.1.0, observed values recipe-sourced, health via verify), tick this box.
- [ ] Complete the census for the flapped five: `cloudai:piface`, `cloudai:pir`, `cloudai:seed`, `cloudai:xf-test`, `cloudai:youtube-mcp`.
  Findings: cloudai's incus daemon endpoint timed out on 2026-09-23 (known flap); retry when it settles.

## Excluded pending Rachid's confirmation

- `cloudai:dokku` - dokku apps (demo-maha, hello-nix); managed by dokku, not cloudify.
- `cloudai:kamal` - kamal-deployed apps (bva-readme, demo-mdx, kamal-deploy-org) + buildkit; managed by kamal.
- `cloudai:openclaw` - silverbullet + papra dockers; no recipes exist in pkg/.
- `cloudai:dsh` - one custom `dsh.service`; no recipe.
- `cloudai:cloudify` - the test container; guacamole-guacd + open-webui there are cloudify E2E residue. Disposable.
- `cloudstation:guac-gui` - only a display-manager (GUI client box); nothing recipe-managed visible.
- `cloudai:pi-web` - nothing visible running.

## Done

- (none yet)
