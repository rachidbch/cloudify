# Runbook: XFCE guest + Guacamole gateway (disposable)

App `xfce-guacamole`, flavor `disposable`: throwaway infrastructure, teardown at the end.
Audience: an agent or human with ONLY `ivps` and `cloudify`.

Rules: variable NAMES only, never values; user-facing URLs and cross-host references are
the full MagicDNS name (`<node>.<tailnet-domain>`), never a bare container name and never an
IP; human-gate steps are mandatory; teardown is mandatory. Fix a failure and re-run the
failed step; use its `verify` to confirm.

## Targets

- Guest: `xfce-test` (Incus container, tag `incus`), created here, deleted after.
- Guacamole host: a docker-capable, tailnet-reachable host. This runbook uses `cloudify`.
- Deployment: `xfce-gui` (cloudify deployment store, ADR-011) = one source of truth.

## Prerequisites

- `ivps` and `cloudify` are authenticated (`cloudify packages` works).
- The Guacamole host runs docker (`cloudify --on cloudify install docker` if needed).
- The tailnet domain for full MagicDNS names (`<node>.<tailnet-domain>`).
- The tailnet ACL lets the Guacamole host reach the guest on port 3389 (step 4 grants it).
- guacd resolves the guest's MagicDNS name from inside its compose network. Open item: no
  check command exists yet; the human gate is the only current proof.

Run the remaining steps in ONE shell: step 2 exports `CLOUDIFY_DEPLOYMENT`, and steps 3-5
need it. In a new shell, prefix commands with `CLOUDIFY_DEPLOYMENT=xfce-gui` or re-run the
`eval`.

## Steps

1. Guest: refresh the tagged authkey, then create the container and join the tailnet.
   ```bash
   ivps tag create incus            # idempotent; refreshes the cached tag authkey
   ivps launch cloudai:xfce-test --tag incus
   ```
   The guest's tailnet identity is `xfce-test.<tailnet-domain>`. The bare name resolves to
   an Incus-internal address on the same node, so never use it across hosts.

2. Shared config: create the deployment, activate it, then set variable NAMES. The
   operator supplies the secret values on stdin; they are never written in this runbook.
   ```bash
   cloudify deployment create xfce-gui
   eval "$(cloudify deployment use xfce-gui)"
   cloudify vars set CLOUDIFY_XFCE_USER gui
   cloudify vars set CLOUDIFY_XFCE_USER_PASSWORD --stdin
   cloudify vars set CLOUDIFY_GUACAMOLE_RDP_HOST "xfce-test.<tailnet-domain>"
   cloudify vars set CLOUDIFY_GUACAMOLE_RDP_USER gui
   cloudify vars set CLOUDIFY_GUACAMOLE_RDP_PASSWORD --stdin
   cloudify vars set CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD --stdin
   cloudify vars set CLOUDIFY_GUACAMOLE_DB_PASSWORD --stdin
   cloudify vars set CLOUDIFY_GUACAMOLE_BIND 127.0.0.1
   cloudify vars list
   ```
   One secret, two names: `CLOUDIFY_XFCE_USER_PASSWORD` and
   `CLOUDIFY_GUACAMOLE_RDP_PASSWORD` must hold the same value (enter it twice from one
   source). The web UI binds loopback; step 6 exposes it over the tailnet.

3. Desktop endpoint on the guest:
   ```bash
   cloudify --on xfce-test install xfce
   cloudify --on xfce-test verify xfce
   ```

4. Reachability (policy): the Guacamole host must reach the guest on port 3389.
   Both are tagged `incus`, and Tailscale denies tag-to-tag by default.
   ```bash
   cloudify exec cloudify 'bash -c "</dev/tcp/xfce-test.<tailnet-domain>/3389"' \
     || ivps acl grant xfce-test --src tag:incus --port 3389
   ivps acl show
   ```

5. Gateway on the Guacamole host:
   ```bash
   cloudify --on cloudify install guacamole
   cloudify --on cloudify verify guacamole
   ```

6. HUMAN GATE (mandatory): expose the web UI over the tailnet and open it from the
   workstation.
   ```bash
   ivps expose-direct cloudai:cloudify 8080
   ```
   Open the printed `https://<host>.<tailnet-domain>` URL, sign in as `guacadmin`, click
   the `GUI` connection, and confirm the XFCE desktop renders and the keyboard works. Do
   not proceed until a human confirms.

7. Teardown (mandatory):
   ```bash
   ivps unexpose cloudai:cloudify --direct
   ivps delete cloudai:xfce-test
   ivps acl revoke xfce-test --src tag:incus --port 3389   # only if granted in step 4
   cloudify deployment delete xfce-gui
   ```

## Notes

- Cross-host references (`CLOUDIFY_GUACAMOLE_RDP_HOST`) are full MagicDNS names, never IPs.
- The Guacamole admin user default is `guacadmin`; set only the password.
