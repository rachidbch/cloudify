# PKG-ADOPTIONS - taking the existing fleet into the deployment model

Census of 2026-09-23 (ivps instances, read-only scans). The legacy registry is empty of real data, so every existing installation is the fog case: adoption, operator-driven.

The flow per entry (agreed with Rachid):

1. Machine investigation (read-only): unit environments, docker inspect, config files.
2. Value table presented: recorded/effective values + confidence flags (`heuristic`, `stale?`, `unknown`).
3. Rachid corrects the wrong values.
4. Deployment shape proposed (name, application/flavor, packages).
5. Disciplined write (configure-gated, ruled 2026-09-27): the observation write records the event + inventory record; the manifest goes `active` only after one real `configure` converges the adopted machine. A live probe proves health, not convergence (a hand-edited unit survives a probe and dies only at configure).

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
- [x] `cloudai:affine` - ADOPTED 2026-09-25; twin proof RUN 2026-09-27 (findings below).
  Investigation complete: deployed by cloudify from our repo (clone + remote + init cookie on the instance); the service RUNS (node 24, listening :8787, live state.db, master token already stored offline by Rachid). The census missed it because it is a systemd USER unit, not system-level.
  Applied values: all recipe defaults (port 8787, dir ~/PROJECTS/affine); no user-supplied values ever (no store file, no declaration before now). Server config surface verified from source: AFFINE_PORT, AFFINE_RATE_LIMIT, AFFINE_RATE_WINDOW_MS, AFFINE_DB (env) + optional .linear-api-key file (compatibility key: clients bearing the real Linear key get an anonymous context; file ABSENT on this machine).
  Rulings so far: record observed effective values as recipe-sourced; backup is EXTERNAL (S3, another agent) - cloudify only writes the contract (what + watch-fors, in pkg/affine/README.md); deployment shape is a first-class application runbook (affine/default/main), not _direct.
  Done: pkg upgraded (split install/configure, all knobs declared, secret marker for the key, v1.1.0); runbooks/affine/default/runbook.md written.
  Adoption write done (event 20260925T165713Z-33a7fe9b, kind adopt): deployment affine/default/main, package affine@default v1.1.0 on cloudai:affine, observed values recipe-sourced (port 8787, dir), last_attempt null (no cloudify attempt ever ran), health ok from the live 401 probe, manifest active pinned at 8a274ce. The production machine was never touched (read-only probe only).
  Twin proof (2026-09-27, throwaway cloudai:affine-twin, `--name twin`): runbook engine end-to-end GREEN (install + verify, manifest active, snapshot written; first attempt died to the shared-scratch bug, fixed same day). Convergence mechanics GREEN (unit rewritten with current values, restart, 401; uninstall leg v1.2.0 proven live incl. --clear-data wipe). Seeded reconfigure (store value 8788 -> payload) BLOCKED BY DESIGN: dispatches write no inventory records yet (worker-after-dispatches wiring is the queued slice), so the applied seed has nothing to read; and the seed's loud refusal was then silently swallowed - cloudify_remote_sync does not guard _cloudify_dispatch_vars' failure, so the payload shipped unseeded (one-line fragile-surface fix, consent requested). Twin and its records torn down cleanly.
  Remaining: the earned configure on cloudai:affine (configure-gated pattern; needs the worker-wiring slice first), and the external baseline backup per the README contract.
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
