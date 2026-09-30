---
targets: anchor
inputs: ZITADEL_DOMAIN
map: CLOUDIFY_ZITADEL_DOMAIN=ZITADEL_DOMAIN
---

# Runbook: zitadel - SecureVault identity anchor

App `zitadel` (flavor `default`). One instance, one package: the official v4
compose stack in external-TLS mode; TLS terminates at Tailscale Serve.
Design provenance and field knowledge: the `zitadel` skill and
`plans/zitadel-pkg.md`; package knobs: `pkg/zitadel/README.md`.

Playable: `cloudify app run zitadel --name main --target anchor=<node>:<instance>`
(install then verify). Teardown is explicit: `--phase teardown`.

## Preconditions

- An ivps instance, tailnet-joined, hostname = ZITADEL_DOMAIN's first label
  (Tailscale Serve answers by that name). The operator launches it:
  `ivps launch <node>:zitadel`.
- Input (once per deployment):
  ```bash
  cloudify vars set ZITADEL_DOMAIN --stdin --deployment zitadel.main
  # e.g. zitadel.komodo-everest.ts.net
  ```

## Steps

### 1. Install the stack

```bash step=install target=anchor pkg=zitadel
cloudify --on "$TARGET_ANCHOR" install zitadel
```

First run pulls ~1.5 GiB and runs instance init; on success the IAM_OWNER
bootstrap PAT sits at `~/zitadel/bootstrap.pat` (0600) on the instance.

### 2. Verify

```bash step=verify target=anchor pkg=zitadel
cloudify --on "$TARGET_ANCHOR" verify zitadel
```

### 3. Expose on the tailnet (auto-TLS edge)

```bash step=run target=anchor phase=expose
ivps expose-direct "$TARGET_ANCHOR" 8080
```

Issuer is https://$ZITADEL_DOMAIN; a mismatch answers "Instance not found".

### 4. Human gate - issuer + PAT handoff

```bash step=human-gate target=anchor phase=expose
```

Check `https://$ZITADEL_DOMAIN/.well-known/openid-configuration` serves and
its `issuer` equals ZITADEL_DOMAIN exactly. Then retrieve the bootstrap PAT
from the instance (it provisions project/app/humans; see the `zitadel` skill)
and store it as a workstation secret.

## Teardown

```bash step=uninstall target=anchor pkg=zitadel phase=teardown
cloudify --on "$TARGET_ANCHOR" uninstall zitadel
```

Destroys the instance data (volumes, masterkey-encrypted); irreversible.
Remove the serve route: `ivps unexpose <node>:zitadel --direct`.
