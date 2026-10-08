---
targets: server
---

# Runbook: t3code - T3 Code v2 headless agent server (nightly)

App `t3code` (flavor `default`). One host, one package: the T3 Code server
(github.com/pingdotgg/t3code) installed by its official installer on the
nightly train, running under a systemd **user** unit (`t3code.service`) owned
by a dedicated non-root user (upstream: root creates a separate installation
and Connect identity). The server listens on loopback `127.0.0.1:3773` only;
clients reach it by pairing - the default here is **T3 Connect** (the vendor's
headless path): an outbound relay with a device-flow approval in any browser.
No policy edits, no tailscale serve hand-wiring, works from anywhere.

Playable: `cloudify app run t3code --name main --target server=<node>:<instance>`
(bare run: install, pair, verify - the pairing gate waits for YOUR approval in
a browser). Teardown is explicit: `--phase teardown`.

## Preconditions

- A tailnet-reachable host managed by cloudify. This runbook never launches
  instances (the engine binds targets against the live inventory before the
  first step), so create the instance first if needed:
  ```bash
  ivps launch cloudai:t3code
  ```
- Nightly protocol: nightly servers need matching clients - the store mobile
  apps cannot connect; use the TestFlight/Play beta or a matching desktop/web
  client (docs/user/updating.md).
- A T3 account and a browser (phone ok) for the approval gate. A provider CLI
  (claude, codex, pi, ...) is NOT installed by this runbook: authenticate at
  least one from the app's Settings -> Providers after pairing, or on the host
  as the T3 user.

## Steps

### 1. Install the server

```bash step=install target=server pkg=t3code id=install-t3code
cloudify --on "$TARGET_SERVER" install t3code
```

Creates the dedicated user, installs `t3` (nightly) from the official
installer, enables linger, registers + starts the user unit, prepares the
headless-Chrome sandbox, then waits for `127.0.0.1:3773` to answer.

### 2. Start the T3 Connect device flow

```bash step=run target=server id=start-connect phase=install
_tmp=$(mktemp)
cat >"$_tmp" <<'HELPER'
#!/usr/bin/env bash
# t3code pairing helper (modes: start | wait | status). Runs t3 as the
# dedicated user with the session env its systemd user manager needs.
set -u
T3_USER="${T3_USER:-t3}"
MODE="${1:?usage: t3-connect-helper.sh start|wait|status}"
LOG="/tmp/t3-connect-${T3_USER}.log"
TUID=$(id -u "$T3_USER")
RUN() { sudo -u "$T3_USER" env HOME="/home/$T3_USER" XDG_RUNTIME_DIR="/run/user/$TUID" PATH="/home/$T3_USER/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }
case "$MODE" in
  start)
    if pgrep -f "connect --headles[s]" >/dev/null 2>&1; then
        echo "A device flow is already running - its details:"; tail -5 "$LOG"; exit 0
    fi
    : > "$LOG"
    printf 'y\n' | nohup RUN t3 connect --headless >> "$LOG" 2>&1 &
    ok=""
    for i in $(seq 1 45); do
        grep -aq "accounts.t3.codes/device" "$LOG" 2>/dev/null && { ok=1; break; }
        sleep 2
    done
    if [ -z "$ok" ]; then echo "No device URL yet - log tail:"; tail -15 "$LOG"; exit 1; fi
    grep -a "Open this URL\|Confirm this code" "$LOG"
    echo "(the flow waits for approval for up to 10 minutes)"
    ;;
  wait)
    for i in $(seq 1 63); do
        pgrep -f "connect --headles[s]" >/dev/null 2>&1 || break
        sleep 10
    done
    if pgrep -f "connect --headles[s]" >/dev/null 2>&1; then
        echo "Still waiting after 10 minutes - the code expired. Re-run from start-connect."; exit 1
    fi
    echo "--- connect log tail ---"; tail -8 "$LOG"
    echo "--- t3 connect status ---"; RUN t3 connect status
    if RUN t3 connect status 2>/dev/null | grep -qi "linked\|authorized\|enabled"; then
        echo "Authorized: restarting the service to activate the relay..."
        RUN t3 service restart
        sleep 5
        RUN systemctl --user is-active t3code.service
    else
        echo "Not authorized yet (declined or timed out). Re-run from start-connect."; exit 1
    fi
    ;;
  status)
    RUN t3 connect status
    ;;
  *)
    echo "unknown mode: $MODE"; exit 2 ;;
esac
HELPER
ivps push "$TARGET_SERVER" "$_tmp" /root/t3-connect-helper.sh
rm -f "$_tmp"
cloudify exec "${TARGET_SERVER##*:}" bash /root/t3-connect-helper.sh start
```

Prints the device-flow URL and the confirmation code to this transcript.

### 3. Approve in your browser (human gate)

```bash step=human-gate target=server id=approve-connect phase=install
echo "Open https://accounts.t3.codes/device, sign in with YOUR T3 account, and approve the code printed by the previous step."
```

A gate step pauses here: open the URL from step 2 on any device, confirm the
code matches, approve. Then confirm this gate. Missed the 10-minute window?
Re-run from `start-connect` (`cloudify app run t3code --from start-connect ...`).
Driving headless (no TTY): the run dies AT this gate by design (`no TTY to
confirm`). That is the expected shape: steps 1-2 already ran and the URL is in
the transcript. After the human approves, resume the rest with
`cloudify app run t3code ... --from wait-connect` (gate not reached, no --yes needed).

### 4. Confirm the link

```bash step=run target=server id=wait-connect phase=install
cloudify exec "${TARGET_SERVER##*:}" bash /root/t3-connect-helper.sh wait
```

Waits for the flow to finish, shows `t3 connect status`, and restarts the
service so the relay tunnel comes up with the authorization in place.

### 5. Verify

```bash step=verify target=server pkg=t3code id=verify-t3code
cloudify --on "$TARGET_SERVER" verify t3code
```

Expect an active `t3code.service` user unit and an answer on `127.0.0.1:3773`.

### 6. Connection status

```bash step=run target=server id=connect-status phase=verify
cloudify exec "${TARGET_SERVER##*:}" bash /root/t3-connect-helper.sh status
```

Then sign in at https://app.t3.codes (or desktop/mobile) with the SAME account
and select the environment. Authenticate a provider in Settings -> Providers.

## Reconfigure

```bash step=configure target=server pkg=t3code id=configure-t3code
cloudify --on "$TARGET_SERVER" configure t3code
```

Converges to the newest release on the channel (or pinned `T3CODE_VERSION`),
re-registers the service, restarts only when the version moved.

## Teardown

```bash step=uninstall target=server pkg=t3code id=teardown-t3code
cloudify --on "$TARGET_SERVER" --clear-data uninstall t3code
```

Flags go before the action (`--clear-data uninstall`). Teardown is a
decommission: service removed, linger off, `~/.t3` (runtime, threads, Connect
identity) and the dedicated user deleted. Deregister the environment from your
T3 account (app.t3.codes -> account -> T3 Connect -> Deregister) to free its
host slot. Then remove the instance and the run's records:

```bash
ivps delete cloudai:t3code
cloudify deployment delete t3code/default/main
```
