---
deployment: affine.main
targets: server
---

# Runbook: affine - clean-room Linear MCP server

App `affine` (flavor `default`). One host, one package. The server replicates
Linear's MCP endpoint; identity lives in its sqlite database (first-boot master
token, then users), configuration is env-only (see `pkg/affine/.remote-vars`).
Backups of `data/` are owned by an external process - see the backup contract
in `pkg/affine/README.md`; this runbook never backs up or restores.

Playable: `cloudify app run affine --name main --target server=<node>:<instance>`
(selects install then verify). Teardown is explicit: `--phase teardown`.

## Preconditions

- A tailnet-reachable host managed by cloudify (the operator provides it; this
  runbook never creates instances).
- No required inputs - every knob has a recipe default. Optional: the secret
  `AFFINE_LINEAR_API_KEY` (compatibility door, see the package README):
  ```bash
  cloudify vars set AFFINE_LINEAR_API_KEY --stdin --deployment affine.main
  ```

## Steps

### 1. Install the server

```bash step=install target=server pkg=affine
cloudify --on "$TARGET_SERVER" install affine
```

On first boot the recipe prints the MASTER token (role master, the only
credential that can mint admins): mint the first admin now and store the
master offline - it is never stored by cloudify.

### 2. Verify

```bash step=verify target=server pkg=affine
cloudify --on "$TARGET_SERVER" verify affine
```

Expect the 401 an unauthenticated MCP call receives on a healthy server.

## Reconfigure

```bash
cloudify --on "$TARGET_SERVER" configure affine
```

Converges the unit and the optional key file onto current values; never
touches the database.

## Teardown

```bash step=uninstall target=server pkg=affine id=teardown-affine
cloudify --on "$TARGET_SERVER" uninstall affine
```

```bash
cloudify deployment delete affine.main
```

The database (`data/`) is removed by the package uninstall only with
`--clear-data`; without it the data stays for the external backup process.
