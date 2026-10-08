---
targets: server
---

# Runbook: t3code - T3 Code v2 headless agent server (nightly)

App `t3code` (flavor `default`). One host, one package: the T3 Code server
(github.com/pingdotgg/t3code) installed by its official installer on the
nightly train, running under a systemd **user** unit (`t3code.service`) owned
by a dedicated non-root user (upstream: root creates a separate installation
and Connect identity). The server listens on loopback `127.0.0.1:3773` only.

**Route decision (Rachid, 2026-10-08): the tailnet IS the boundary.** The
server is published tailnet-only through ivps (`expose-service` -> `svc:t3`,
ACL-gated, tailscale TLS). No T3 Connect: its outbound cloudflared relay
makes the box reachable from the whole internet behind only a T3-account
credential - a wider surface than the tailnet ACL it would bypass. T3
Connect stays a documented opt-in (`t3 connect --headless`, device flow) for
genuinely off-tailnet access.

Playable: `cloudify app run t3code --name main --target server=<node>:<instance>`
(bare run: install, publish, pair - the gate waits for YOU to paste the
pairing URL into the app). Teardown is explicit: `--phase teardown`.

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
- A browser on the tailnet for the pairing gate. A provider CLI (claude,
  codex, pi, ...) is NOT installed by this runbook: authenticate at least one
  from the app's Settings -> Providers after pairing, or on the host as the
  T3 user.

## Steps

### 1. Install the server

```bash step=install target=server pkg=t3code id=install-t3code
cloudify --on "$TARGET_SERVER" install t3code
```

Creates the dedicated user, installs `t3` (nightly) from the official
installer, enables linger, registers + starts the user unit, prepares the
headless-Chrome sandbox, then waits for `127.0.0.1:3773` to answer.

### 2. Publish tailnet-only (ivps service)

```bash step=run target=server id=expose-service phase=install
ivps expose-service "$TARGET_SERVER" t3 3773
```

Registers the `svc:t3` VIP (ACL-managed, tailscale TLS) and prints the
`https://t3.<tailnet>` URL. Done = `Service 'svc:t3' is LIVE`.

### 3. Mint the pairing URL

```bash step=run target=server id=mint-pair phase=install
_tmp=$(mktemp)
cat >"$_tmp" <<'HELPER'
#!/usr/bin/env bash
# t3code pairing helper - mints a one-time pairing token on the running
# server and rewrites it onto the tailnet service URL. Runs t3 as the
# dedicated user with the session env its systemd user manager needs.
set -u
T3_USER="${T3_USER:-t3}"
SVC_HOST="${1:?usage: t3-connect-helper.sh <service-host>}"
LOG="/tmp/t3-pair-${T3_USER}.log"
TUID=$(id -u "$T3_USER")
RUN() { runuser -u "$T3_USER" -- env HOME="/home/$T3_USER" XDG_RUNTIME_DIR="/run/user/$TUID" PATH="/home/$T3_USER/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }
RUN t3 pair --ttl 1h --label "t3code tailnet" >"$LOG" 2>&1 || { tail -5 "$LOG"; exit 1; }
_url=$(grep -a "Pairing URL" "$LOG" | grep -o "http://localhost:3773/pair#token=[A-Za-z0-9]*")
[ -n "$_url" ] || { echo "No pairing URL minted - log tail:"; tail -5 "$LOG"; exit 1; }
echo "One-time pairing URL (valid 1h - treat as a password):"
echo "${_url/http:\/\/localhost:3773/https://${SVC_HOST}}"
HELPER
ivps push "$TARGET_SERVER" "$_tmp" /root/t3-connect-helper.sh
rm -f "$_tmp"
_svc_host=$(ivps expose-service verify svc:t3 | grep -o 'https://t3\.[^ /]*' | head -1 | sed 's|https://||')
cloudify exec "${TARGET_SERVER##*:}" bash /root/t3-connect-helper.sh "$_svc_host"
```

Mints a one-time pairing token on the running server (TTL 1 hour) and
prints the pairing URL rewritten onto the tailnet service host. The token
rides in the URL fragment: it stays in the browser, never reaches the wire.

### 4. Pair your client (human gate)

```bash step=human-gate target=server id=approve-pair phase=install
echo "Open https://app.t3.codes (desktop/mobile app: Add environment), paste the pairing URL from the previous step, confirm."
```

A gate step pauses here: paste the URL into the app's Add-environment field
(web: app.t3.codes; mobile: beta app on the tailnet). Then confirm this
gate. Expired? Re-run from `mint-pair` for a fresh token. Driving headless
(no TTY): the run dies AT this gate by design (`no TTY to confirm`) - steps
1-3 already ran and the URL is in the transcript; resume with
`cloudify app run t3code ... --from verify-t3code`.

### 5. Verify

```bash step=verify target=server pkg=t3code id=verify-t3code
cloudify --on "$TARGET_SERVER" verify t3code
```

Expect an active `t3code.service` user unit and an answer on `127.0.0.1:3773`.

### 6. Service live

```bash step=run target=server id=service-live phase=verify
ivps expose-service verify svc:t3
```

Expect `Service 'svc:t3' is LIVE ... (HTTP 200)`. Then authenticate a
provider in the app: Settings -> Providers.

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
decommission: service removed, linger off, `~/.t3` (runtime, threads, pairing
grants) and the dedicated user deleted. Then unpublish, remove the instance
and the run's records:

```bash
ivps unexpose cloudai:t3code --service t3
ivps delete cloudai:t3code
cloudify deployment delete t3code/default/main
```
