# pi-pocket

[Pi Pocket](https://github.com/TannerMidd/pi-pocket) - a durable, multiplayer,
mobile-first web app for Pi agents. A Node service behind its own systemd unit.

Level 1 adoption (2026-10-20): the recipe and runbook describe the deployment
already running on `cloudai:pocket-box` (v0.15.0, node v22, port 8787, access
`lan`). No state is recorded by level 1; that is the level 2 step.

## Install

```bash
cloudify --on <host> install pi-pocket
```

Requires `PI_POCKET_REPO` - the git repository the host deploys from. The
observed host deploys from a bare repo on the machine itself
(`/srv/pi-pocket.git`).

Convergence, not duplication: when `/opt/pi-pocket` is already a checkout,
install fetches, hard-resets to `origin/<PI_POCKET_REF>` and runs `npm ci`.

## Configuration

Declared names (`.remote-vars`), all with recipe defaults: `PI_POCKET_PORT`
(8787), `PI_POCKET_ACCESS` (lan), `PI_POCKET_DIR` (/opt/pi-pocket),
`PI_POCKET_DATA` (/var/lib/pi-pocket), `PI_POCKET_SERVICE` (pi-pocket). Also
read, undeclared because they have no safe default: `PI_POCKET_REPO` (required),
`PI_POCKET_REF` (main), `PI_POCKET_NODE` (/usr/bin/node).

## Verification

`pkg_verify` checks three facts in order: the unit is active, the port is
bound, and `GET /` answers. The listener check is separate from the HTTP check
on purpose - a bound port with a failing app is drift, not absence.

## Teardown

Removes the unit and `/opt/pi-pocket`. `/var/lib/pi-pocket` (durable agents,
threads, attachments) survives unless `--clear-data` is given.
