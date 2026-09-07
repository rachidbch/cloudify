# Runbook: XFCE guest + Guacamole gateway E2E (disposable)

Status: acceptance gate for pkg/xfce + pkg/guacamole (both integration-green).
Pure commands only: ivps + cloudify + one orchestrator-side password generation.
No custom scripts, no ad-hoc host commands. Data flows through command output
into deployment vars. Production oracle (cloudstation) untouched (decision 3).

## Targets (disposable)

- Guest: cloudai:xfce-test (Incus container, tag:incus) - created here, deleted after.
- Guacamole host: docker-capable, tailnet-reachable, chosen at execution time; must
  reach the guest:3389 through the ACL (ivps acl show/grant governs).
- Human: Rachid browser session at the end (render + keyboard) = acceptance.

## Steps

```bash
# 1. Guest (ivps): container + tailnet join with tag:incus
ivps launch cloudai:xfce-test --tag incus

# 2. Shared config (cloudify deployment store, ADR-011): one source of truth.
#    RDP_HOST = guest tailnet IP from `ivps info xfce-test` (command output -> vars).
#    Password generated ONCE here, orchestrator-side; both pkgs consume env-passed.
PW=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
cloudify deployment create xfce-gui
cloudify deployment vars set xfce-gui RDP_HOST=<guest-tailnet-ip> RDP_PASSWORD=$PW XFCE_USER=gui

# 3. Desktop endpoint (cloudify, on the guest)
cloudify deployment use xfce-gui     # or CLOUDIFY_DEPLOYMENT=xfce-gui prefix per command
cloudify --on xfce-test install xfce     # env-passed password set at user creation
cloudify --on xfce-test verify xfce      # xrdp active, :3389 listening, chrome, session

# 4. Reachability (policy, ivps): the guacamole host must reach the guest:3389.
#    Declared via `ivps acl grant <guacamole-host-or-tag> --dst <guest-or-tag> --port 3389`
#    (check first with `ivps acl show`; revoke/rollback after the test).

# 5. Gateway (cloudify, on the docker host): record upsert from deployment vars
cloudify --on <guacamole-host> configure guacamole   # connection record (host/port/user/password)
cloudify --on <guacamole-host> verify guacamole      # stack healthy, record matches, bind answers

# 6. Human acceptance (Rachid): open the guacamole web UI (bind must be
#    tailnet-reachable from the workstation), click the connection, verify XFCE
#    renders and keyboard input works. This is the unautomatable E2E proof.

# 7. Teardown (disposable): delete guest, revoke the temporary ACL grant,
#    remove the deployment.
```

## Failure handling (debug ladder, not runbook steps)

Reachability red: diagnose with tailnet probes (nc from the guacamole host, ivps
acl show) and fix the ACL or the guest service - then re-run verify, not the e2e.
Render red: check the connection record params (resize-method, security) against
the SOP oracle facts before touching the guest.

## Notes

- Password: generation at orchestration level (this runbook); xfce's generate+print
  path exists for standalone installs without a deployment.
- Guacamole bind: for the human session the web UI must bind an address the
  workstation can reach over the tailnet (explicit CLOUDIFY_GUACAMOLE_BIND).
