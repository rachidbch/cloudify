---
targets: server
---

# Runbook: octop - self-hosted AI assistant

App `octop` (flavor `default`). One host, one package: the Octop server
(github.com/TencentCloud/Octop) installed by its official installer (pinned
`OCTOP_VERSION`), running under its own systemd user unit `octop`, all state
under `~/.octop/` on the target.

No credential inputs: at first boot (zero users) the server mints a one-time
wizard password (`~/octop-login.txt` on the target, printed by the install
step). The operator opens the dashboard, pastes it into the setup wizard,
and creates the admin with their own username and password. Cloudify never
sees or stores admin credentials.

Playable: `cloudify app run octop --name main --target server=<node>:<instance>`
(bare run: install then verify). Teardown is explicit: `--phase teardown`.

## Preconditions

- A tailnet-reachable host managed by cloudify (the operator provides it; this
  runbook never creates instances).
- No required inputs - every knob has a recipe default. Recommended deployment
  value: `OCTOP_BIND_HOST=0.0.0.0` (dashboard reachable over the tailnet).
  ```bash
  cloudify vars set OCTOP_BIND_HOST 0.0.0.0 --deployment octop.main
  ```

## Steps

### 1. Install the server

```bash step=install target=server pkg=octop
cloudify --on "$TARGET_SERVER" install octop
```

On first boot the step prints the one-time wizard password: open the
dashboard (`http://<target>:8088`), paste it into the setup wizard, create
the admin with your own credentials. The file self-removes after use.

### 2. Verify

```bash step=verify target=server pkg=octop
cloudify --on "$TARGET_SERVER" verify octop
```

Expect an active `octop` user unit and a healthy `GET /api/health` (`"ok":true`).

## Reconfigure

```bash
cloudify --on "$TARGET_SERVER" configure octop
```

Converges the env file (port, bind host, log level) and restarts only when
something changed; never touches the database or the unit file.

## Teardown

```bash step=uninstall target=server pkg=octop id=teardown-octop
cloudify --on "$TARGET_SERVER" --clear-data uninstall octop
```

Flags go before the action (`--clear-data uninstall`, not `uninstall
--clear-data`). Without `--clear-data` the state (`~/.octop`, database,
workspaces) stays; with it the whole directory dies - users, agents, memory.
