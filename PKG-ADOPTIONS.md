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
- [ ] `cloudai:affine` - recipe exists, machine shows nothing.
  Findings: `affine` recipe in pkg/; no docker containers, no custom units visible.
  Open question: dead deployment (recipe removed from machine) or invisible install method?
  Status: awaiting Rachid's ruling.
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
