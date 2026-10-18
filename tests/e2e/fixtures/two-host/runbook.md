---
targets: alpha, beta
---

# Two-host application

The disposable fixture package lands on both hosts.

```bash step=install target=alpha pkg=fixture-split
cloudify --on "$TARGET_ALPHA" install fixture-split
```

```bash step=verify target=alpha pkg=fixture-split
cloudify --on "$TARGET_ALPHA" verify fixture-split
```

```bash step=install target=beta pkg=fixture-split
cloudify --on "$TARGET_BETA" install fixture-split
```

```bash step=verify target=beta pkg=fixture-split
cloudify --on "$TARGET_BETA" verify fixture-split
```
