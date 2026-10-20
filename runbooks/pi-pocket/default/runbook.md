---
targets: server
---

# Runbook: pi-pocket - durable web app for Pi agents

App `pi-pocket` (flavor `default`). One host, one package: Pi Pocket
(github.com/TannerMidd/pi-pocket), a Node service that gives Pi agents a
durable, multiplayer, mobile-first web UI. It runs under its own systemd unit
`pi-pocket.service`, keeps its source at `/opt/pi-pocket` and its durable state
(agents, threads, attachments) at `/var/lib/pi-pocket`.

Level 1 adoption: this runbook and the recipe describe the deployment that
already runs on `cloudai:pocket-box`; running it converges that same shape.
State back-fill is level 2 and is a separate, approved step.

Playable: `cloudify app run pi-pocket --name main --target server=<node>:<instance>`
(bare run: install then verify). Teardown is explicit: `--phase teardown`, and
keeps the data directory unless `--clear-data` is also given.

## Preconditions

- A tailnet-reachable host managed by cloudify (the operator provides it; this
  runbook never creates instances).
- `PI_POCKET_REPO` is required - the git repository the host deploys from.
  The observed host deploys from a bare repo on the machine itself
  (`/srv/pi-pocket.git`), which is a host-local path, not a public URL.
- Node is a package dependency (`pkg_depends node`); the observed host runs
  node v22.

## Steps

### 1. Install / converge

```bash step=install target=server pkg=pi-pocket
cloudify --on "$TARGET_SERVER" install pi-pocket
```

Converges rather than clones when `/opt/pi-pocket` is already a checkout:
fetch, hard reset to `origin/<PI_POCKET_REF>`, then `npm ci`. The unit is
rewritten from the recorded values and restarted, so a value change is a
reinstall of the same shape, never a second deployment.

### 2. Verify

```bash step=verify target=server pkg=pi-pocket
cloudify --on "$TARGET_SERVER" verify pi-pocket
```

Three facts in order: the unit is active, the port is bound, and the app
answers HTTP. A bound port with a failing app is drift, not absence.

### 3. Teardown

```bash step=uninstall target=server pkg=pi-pocket
cloudify --on "$TARGET_SERVER" uninstall pi-pocket
```

Removes the unit and the checkout. Keeps `/var/lib/pi-pocket` unless
`--clear-data` is passed: the agent state is not reproducible from the repo.
