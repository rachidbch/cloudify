# Runbook: XFCE guest + Guacamole gateway (server side)

App `xfce-guacamole`. Audience: an agent or human with ONLY `ivps` and `cloudify`.
This runbook deploys the software onto PROVIDED instances; it never creates or deletes them.

Rules: variable NAMES only, never values; cross-host references are full MagicDNS names
(`<node>.<tailnet-domain>`), never a bare container name and never an IP; human-gate steps
are mandatory; teardown removes the software, never the instances.

Scope the deployment explicitly on EVERY cloudify command that consumes its vars
(`--deployment xfce-gui` for `vars`, `CLOUDIFY_DEPLOYMENT=xfce-gui` for install/configure/
verify/uninstall). Do not rely on ambient shell state.

## Inputs (provided by the operator; not created here)

- Guest: a tailnet-reachable host, managed by cloudify. This runbook uses `xfce-test`.
- Guacamole host: a docker-capable, tailnet-reachable host. This runbook uses `cloudify`.
- Guacamole host's ivps node: this runbook uses `cloudai` (as shown by `ivps list`).
- Tailnet domain: the operator's MagicDNS domain (e.g. `komodo-everest.ts.net`).
- Deployment id: `xfce-gui`.

## Preconditions (must already hold)

- Both hosts are reachable by cloudify (`cloudify --on <host> verify`-able).
- The guest is a tailnet node, so `<guest>.<tailnet-domain>` resolves.
- The Guacamole host runs docker.
- Tailnet policy lets the Guacamole host reach the guest on port 3389. If not, the operator
  grants it (infrastructure, outside this runbook):
  `ivps acl grant tag:incus --src tag:incus --port 3389`.

## Steps

1. Shared config: create the deployment and set variable NAMES with an explicit
   `--deployment`. The operator supplies the secret values on stdin; they are never written
   in this runbook.
   ```bash
   cloudify deployment create xfce-gui
   cloudify vars set CLOUDIFY_XFCE_USER gui --deployment xfce-gui
   cloudify vars set CLOUDIFY_XFCE_USER_PASSWORD --stdin --deployment xfce-gui
   cloudify vars set CLOUDIFY_GUACAMOLE_RDP_HOST "<guest>.<tailnet-domain>" --deployment xfce-gui
   cloudify vars set CLOUDIFY_GUACAMOLE_RDP_USER gui --deployment xfce-gui
   cloudify vars set CLOUDIFY_GUACAMOLE_RDP_PASSWORD --stdin --deployment xfce-gui
   cloudify vars set CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD --stdin --deployment xfce-gui
   cloudify vars set CLOUDIFY_GUACAMOLE_DB_PASSWORD --stdin --deployment xfce-gui
   cloudify vars set CLOUDIFY_GUACAMOLE_BIND 127.0.0.1 --deployment xfce-gui
   cloudify vars list --deployment xfce-gui
   ```
   One secret, two names: `CLOUDIFY_XFCE_USER_PASSWORD` and
   `CLOUDIFY_GUACAMOLE_RDP_PASSWORD` must hold the same value (enter it twice from one
   source). `CLOUDIFY_XFCE_USER_PASSWORD` is consumed only when the account is CREATED: if it
   is missing then, the recipe generates a password and a later run will not change the
   existing account. Get it right on the first install.

2. Desktop endpoint on the guest:
   ```bash
   CLOUDIFY_DEPLOYMENT=xfce-gui cloudify --on <guest> install xfce
   CLOUDIFY_DEPLOYMENT=xfce-gui cloudify --on <guest> verify xfce
   ```

3. Gateway on the Guacamole host:
   ```bash
   CLOUDIFY_DEPLOYMENT=xfce-gui cloudify --on <guacamole-host> install guacamole
   CLOUDIFY_DEPLOYMENT=xfce-gui cloudify --on <guacamole-host> verify guacamole
   ```

4. Peer reachability: the Guacamole stack must reach the guest on 3389, and guacd must
   resolve the guest's MagicDNS name from inside its compose network. The compose project is
   the package directory name (`guacamole`), so the service container is `guacamole-guacd-1`.
   ```bash
   cloudify exec <guacamole-host> 'docker exec guacamole-guacd-1 getent hosts <guest>.<tailnet-domain>'
   ```

5. HUMAN GATE (mandatory): expose the web UI over the tailnet and open it from the
   workstation. `8080` is the Guacamole web port; the container publishes it on loopback
   (step 1), so this proxies it to the tailnet.
   ```bash
   ivps expose-direct cloudai:<guacamole-host> 8080
   ```
   Open the printed `https://<host>.<tailnet-domain>` URL, sign in as `guacadmin`, click the
   `GUI` connection, and confirm the XFCE desktop renders and the keyboard works. Do not
   proceed until a human confirms.

6. Teardown (software only; the instances stay):
   ```bash
   CLOUDIFY_DEPLOYMENT=xfce-gui cloudify --on <guest> uninstall xfce
   CLOUDIFY_DEPLOYMENT=xfce-gui cloudify --on <guacamole-host> uninstall guacamole
   ivps unexpose cloudai:<guacamole-host> --direct
   cloudify deployment delete xfce-gui
   ```

## Notes

- Cross-host references (`CLOUDIFY_GUACAMOLE_RDP_HOST`) are full MagicDNS names, never IPs.
- The Guacamole admin user default is `guacadmin`; set only the password.
- Expected noise, not failure: `CLOUDIFY_GUACAMOLE_ADMIN_USER ... unset` WARN (the admin user
  defaults to `guacadmin`) and repeated `bash: - : invalid option` lines (a known cloudify
  logging bug; ROADMAP).
- `vars set ... --stdin` reads raw bytes; a trailing newline is preserved. Use `printf '%s'`
  when the value must not end with a newline.
