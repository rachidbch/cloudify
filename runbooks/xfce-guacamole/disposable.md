# Runbook: XFCE guest + Guacamole gateway (disposable)

App `xfce-guacamole`, flavor `disposable`: throwaway infrastructure, teardown at the end.
Audience: an agent or human with ONLY `ivps` and `cloudify`. No ad-hoc scripts, no host commands.

Rules: variable NAMES only, never values; addresses are MagicDNS names, never IPs;
human-gate steps are mandatory; teardown is mandatory. Fix a failure and re-run that
step's `verify`, not the whole runbook.

## Targets

- Guest: `xfce-test` (Incus container, tag `incus`), created here, deleted after.
- Guacamole host: a docker-capable, tailnet-reachable host. This runbook uses `cloudify`.
- Deployment: `xfce-gui` (cloudify deployment store, ADR-011) = one source of truth.

## Prerequisites

- `ivps` and `cloudify` are authenticated (`cloudify packages` works).
- The Guacamole host runs docker (`cloudify --on cloudify install docker` if needed).
- The ACL lets the Guacamole host reach the guest on port 3389 (step 4 checks/grants).
- guacd resolves MagicDNS names from inside its compose network (validated once).

## Steps

1. Guest: create the container and join the tailnet.
   ```bash
   ivps launch cloudai:xfce-test --tag incus
   ```
   Note the guest's MagicDNS name (not its IP): `ivps info xfce-test`.

2. Shared config: create the deployment, then set variable NAMES. The operator supplies
   the secret values on stdin; they are never written in this runbook.
   ```bash
   cloudify deployment create xfce-gui
   cloudify vars set CLOUDIFY_XFCE_USER gui --deployment xfce-gui
   cloudify vars set CLOUDIFY_XFCE_USER_PASSWORD --stdin --deployment xfce-gui
   cloudify vars set CLOUDIFY_GUACAMOLE_RDP_HOST xfce-test --deployment xfce-gui
   cloudify vars set CLOUDIFY_GUACAMOLE_RDP_USER gui --deployment xfce-gui
   cloudify vars set CLOUDIFY_GUACAMOLE_RDP_PASSWORD --stdin --deployment xfce-gui
   cloudify vars set CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD --stdin --deployment xfce-gui
   cloudify vars set CLOUDIFY_GUACAMOLE_DB_PASSWORD --stdin --deployment xfce-gui
   cloudify vars set CLOUDIFY_GUACAMOLE_BIND "$(ivps info cloudify --field ipv4)" --deployment xfce-gui
   ```
   One secret, two names: `CLOUDIFY_XFCE_USER_PASSWORD` and
   `CLOUDIFY_GUACAMOLE_RDP_PASSWORD` must hold the same value (enter it twice from one
   source). `CLOUDIFY_GUACAMOLE_BIND` is the Guacamole host's own tailnet address,
   derived at run time, never hardcoded.

3. Desktop endpoint on the guest:
   ```bash
   cloudify --on xfce-test install xfce
   cloudify --on xfce-test verify xfce
   ```

4. Reachability (policy):
   ```bash
   ivps acl show
   # if the Guacamole host cannot reach the guest on 3389:
   ivps acl grant cloudify --dst xfce-test --port 3389
   ```

5. Gateway on the Guacamole host:
   ```bash
   cloudify --on cloudify install guacamole
   cloudify --on cloudify verify guacamole
   ```

6. HUMAN GATE (mandatory): open the Guacamole web UI from the workstation
   (`http://cloudify:8080/`), sign in as the admin user, click the `GUI` connection,
   confirm the XFCE desktop renders and the keyboard works. Do not proceed until a
   human confirms.

7. Teardown (mandatory):
   ```bash
   ivps delete cloudai:xfce-test
   ivps acl revoke cloudify --dst xfce-test --port 3389   # only if granted in step 4
   cloudify deployment delete xfce-gui
   ```

## Notes

- Cross-host references (`CLOUDIFY_GUACAMOLE_RDP_HOST`) are MagicDNS names, never IPs.
- The Guacamole admin user default is `guacadmin`; set only the password.
