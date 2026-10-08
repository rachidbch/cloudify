# pkg/t3code - T3 Code (pingdotgg/t3code), nightly train

T3 Code v2 runs coding agents (Claude Code, Codex, ...) on a host and exposes
them to the web/desktop/mobile apps. This package provisions the headless
server (`t3`) as a systemd **user** service owned by a dedicated non-root
user, installed by the **official installer** (`https://t3.codes/install.sh`)
on the channel you pick. Nothing here ever handles credentials: linking the
server to a T3 account is an operator interaction (`t3 connect --headless`
device flow), driven by the `t3code` runbook.

## Layout on the target

- Dedicated user `T3CODE_USER` (default `t3`) - upstream: running T3 Code as
  root creates a separate installation and Connect identity. Never root.
- `$T3_HOME = /home/<user>/.t3` - runtime (`runtime/versions/<v>`) AND all
  userdata (`userdata/`: projects, threads, settings, logs).
- `~/.local/bin/t3` - symlink to the linked version's binary.
- `~/.config/systemd/user/t3code.service` - written by `t3 service install`,
  pinned to the exact version path; `Restart=always`.
- Lingering is enabled for the user (server survives logout, starts at boot).

## Config (declared in `.remote-vars`; recipe default stays runtime truth)

- `T3CODE_CHANNEL` (default `nightly`) - stable | nightly | preview.
- `T3CODE_VERSION` (default empty = newest on the channel; empty is NOT
  mirrored as a value in `.remote-vars`).
- `T3CODE_USER` (default `t3`).
- `T3CODE_PORT` (default `3773`) - verified real default (docs don't name it).

## Verified on ubuntu/24.04 cloud container (probe, v0.0.46-nightly)

- The `t3` binary needs `libatomic.so.1` -> dependency `libatomic1`; the
  installer self-tests the binary and refuses a broken install.
- `t3 service install` under `sudo -u` fails `[user-manager-unavailable]`
  unless `XDG_RUNTIME_DIR=/run/user/<uid>` is exported: the user manager IS
  running (linger on), sudo simply doesn't point at its socket. All user
  invocations here go through `_uenv` with the full session env.
- `t3 browser setup` (headless-Chrome sandbox AppArmor profile) needs the
  `apparmor` package on the container, then succeeds. Without it, browser
  tabs need `T3CODE_SERVER_BROWSER_SANDBOX=0`.
- Server binds `127.0.0.1:3773`, logs to
  `~/.t3/userdata/logs/boot-service.log`, prints a pairing URL at boot.

## Lifecycle

- `install` - deps, user, installer, linger, service, browser sandbox, health
  wait. Guarded: skips when binary + unit + active service all hold.
- `configure` - converge: linger, installer re-run (newest on channel, or
  pinned `T3CODE_VERSION`), service re-registration, restart only when the
  linked version moved. This is the update path (`t3 update` equivalent).
- `uninstall` - `t3 service uninstall` + linger off. `~/.t3` (userdata) is
  kept unless `--clear-data`, which removes `~/.t3` AND the user
  (decommission: account link, threads, everything).

## Pairing (operator, after install - runbook owns it)

**Default route - the tailnet is the boundary (Rachid, 2026-10-08):**
publish tailnet-only with ivps (`ivps expose-service <node>:<instance> t3 3773`
-> `svc:t3`, ACL-gated, tailscale TLS), mint a one-time pairing token
(`t3 pair --ttl 1h` as the T3 user) and rewrite its URL onto the service host
(`https://t3.<tailnet>/pair#token=...`). Paste into app.t3.codes / Add
environment. The secret rides in the URL fragment (stays in the browser).
No inbound exposure beyond the ACL, no relay, no account needed.

**Opt-in - T3 Connect (off-tailnet access):** `t3 connect --headless` -
downloads the relay client (cloudflared) on first use, prints
`https://accounts.t3.codes/device?user_code=XXXX-XXXX`, waits up to 10
minutes for approval in any browser. The environment becomes reachable from
the whole internet behind the T3 account - a WIDER surface than the tailnet
ACL; use only when genuinely needed. Tear down with `t3 connect logout`.

**Also available:** `t3 pair` over an SSH tunnel (local-only); token TTL
5 minutes by default.

## Nightly client compatibility

A client and the server must speak the same protocol version: nightly servers
refuse older clients and vice versa (docs/user/updating.md). The store mobile
apps cannot connect to nightlies - use the beta app (TestFlight / Play beta
track) or a matching desktop/web client.

## Provider CLIs

The server needs at least one provider CLI (claude, codex, pi, ...) on the
user's PATH, authenticated - install/auth from the app's Settings -> Providers
after pairing, or on the host as the T3 user.
