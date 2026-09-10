---
deployment: demo-bind
targets: guest
---

```bash step=install target=guest pkg=demo-pkg
cloudify --on "$TARGET_GUEST" install demo-pkg
```
