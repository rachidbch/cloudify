---
deployment: demo
targets: guest, gateway
---

# Demo runbook

The guest runs the desktop; the gateway proxies it.

```bash step=install target=guest pkg=demo-pkg
cloudify --on "$TARGET_GUEST" install demo-pkg
# a second body line so multi-line bodies round-trip
echo done
```

```bash step=verify target=guest pkg=demo-pkg id=check-guest
cloudify --on "$TARGET_GUEST" verify demo-pkg
```

```bash step=human-gate
Open the URL and confirm the desktop renders.
```
