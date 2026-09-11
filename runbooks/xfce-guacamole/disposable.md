---
deployment: xfce-gui
targets: guest, gateway
---

# Runbook: XFCE guest + Guacamole gateway (server side)

App `xfce-guacamole`. Audience: an agent or human with ONLY `ivps` and `cloudify`.
This runbook deploys the software onto PROVIDED instances; it never creates or deletes them.

Rules: variable NAMES only, never values; cross-host references are full MagicDNS names
(`<guest>.<tailnet-domain>`), never a bare container name and never an IP; human-gate steps
are mandatory; teardown removes the software, never the instances.

Playable: `cloudify deployment run xfce-gui` executes the `step=` blocks in order, with the
deployment set and the targets bound. Target names take environment variables
`$TARGET_GUEST` and `$TARGET_GATEWAY`. Bind them per run:
`--target guest=<node>:<guest> --target gateway=<node>:<gateway>` (or store the same values
as `TARGET_GUEST` / `TARGET_GATEWAY` in the deployment). Plain fenced blocks are operator
commands, not run by the engine.

## Inputs (provided by the operator; not created here)

- Guest: a tailnet-reachable host, managed by cloudify.
- Gateway: a docker-capable, tailnet-reachable host (runs guacd + Guacamole).
- Tailnet domain: the operator's MagicDNS domain.
- Deployment id: `xfce-gui` (the front-matter above).

## Preconditions (must already hold)

- Both hosts are reachable by cloudify (`cloudify --on <host> verify`-able).
- The gateway runs docker.
- Tailnet RDP reachability: the gateway may open the guest's RDP port. Tailscale policy
  selects devices by tag only, so name the two roles instead of granting the default
  container tag to itself:
  ```bash
  ivps tag create rdp-client
  ivps tag create rdp-server
  # tag set REPLACES the device's whole list: containers must keep tag:incus (the ssh rule
  # and the lighthouse/hermes grants reference it).
  ivps tag set <guest>   tag:incus tag:rdp-server
  ivps tag set <gateway> tag:incus tag:rdp-client
  ivps acl grant tag:rdp-server --src tag:rdp-client --port 3389
  ```
  Verify before proceeding: `ivps acl show --section acl` lists the row and
  `ivps acl show --section ssh` is unchanged. Record the snapshot path ivps prints. Never
  grant `tag:incus` to `tag:incus` (any-to-any; the branch-6 defect).
- Deployment values (operator, secrets from stdin; never written here):
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
  `CLOUDIFY_GUACAMOLE_RDP_PASSWORD` must hold the same value. The xfce password is consumed
  only when the account is CREATED: a later run cannot change it.

## Steps

### 1. Desktop endpoint on the guest

```bash step=install target=guest pkg=xfce
cloudify --on "$TARGET_GUEST" install xfce
```

```bash step=verify target=guest pkg=xfce
cloudify --on "$TARGET_GUEST" verify xfce
```

### 2. Gateway on the gateway host

```bash step=install target=gateway pkg=guacamole
cloudify --on "$TARGET_GATEWAY" install guacamole
```

```bash step=verify target=gateway pkg=guacamole
cloudify --on "$TARGET_GATEWAY" verify guacamole
```

### 3. Expose the web UI over the tailnet

`8080` is the Guacamole web port; the container publishes it on loopback (a deployment
value), so this proxies it to the tailnet.

```bash step=run target=gateway
ivps expose-direct "$TARGET_GATEWAY" 8080
```

### 4. HUMAN GATE (mandatory)

```bash step=human-gate
Open the printed https://<gateway>.<tailnet-domain> URL, sign in as guacadmin, click the
GUI connection, and confirm the XFCE desktop renders and the keyboard works. Do not proceed
until a human confirms.
```

## Teardown

**This phase must never run in the forward run.** The engine executes steps in document
order, so `cloudify deployment run xfce-gui --yes` would auto-confirm the human gate and then
run the blocks below, destroying the deployment before anyone looks at it. Run them
explicitly, after the gate, starting at the first teardown step:

```bash
cloudify deployment run xfce-gui --target guest=<guest> --target gateway=<gateway> --from teardown-xfce
```

Order (each item is load-bearing):

1. **Software legs first** - they need ssh and the RDP path alive.
2. **Deployment delete** - drops the deployment store and its registry records.
3. **Policy and identity last** - revoke the grant *before* deleting a role tag (the API
   rejects a tag still referenced by a grant), and only after no software needs the path:
   revoking earlier kills guacd -> RDP mid-teardown.
4. **Instances**: ones the operator PROVIDED are never deleted here; only the software is
   removed. A runbook that launched an instance may delete only that instance.
5. Remove **only what this run added**. Keep the snapshot path ivps prints; prove the
   policy flipped before claiming done.

```bash step=uninstall target=guest pkg=xfce id=teardown-xfce
cloudify --on "$TARGET_GUEST" uninstall xfce
```

```bash step=uninstall target=gateway pkg=guacamole id=teardown-guacamole
cloudify --on "$TARGET_GATEWAY" uninstall guacamole
```

```bash step=run target=gateway id=teardown-unexpose
ivps unexpose "$TARGET_GATEWAY" --direct
```

Operator, after the software legs (keep this order):

```bash
cloudify deployment delete xfce-gui
```

The role tags and their grant are usually **kept** so later runs reuse the role. Retire them
only when the role is no longer needed, in this order:

```bash
# 1. revoke the grant (grants only; never --ssh)
ivps acl revoke tag:rdp-server --src tag:rdp-client --port 3389
# 2. reset the tags on the devices this run tagged (they must keep tag:incus)
ivps tag set <gateway> tag:incus
ivps tag set <guest>   tag:incus
# 3. delete the tag declarations last (API rejects a tag still in use)
ivps tag delete rdp-client
ivps tag delete rdp-server
```

Prove it: `ivps acl show --section acl` no longer lists the row, and `ivps tag list` no
longer shows the role tags. Deleting containers is not enough - policy outlives them.

## Notes

- Cross-host references (`CLOUDIFY_GUACAMOLE_RDP_HOST`) are full MagicDNS names, never IPs.
- The Guacamole admin user default is `guacadmin`; set only the password.
- Expected noise, not failure: `CLOUDIFY_GUACAMOLE_ADMIN_USER ... unset` WARN (the admin
  user defaults to `guacadmin`) and repeated `bash: - : invalid option` lines (a known
  cloudify logging bug; ROADMAP).
- `vars set ... --stdin` reads raw bytes; a trailing newline is preserved.
