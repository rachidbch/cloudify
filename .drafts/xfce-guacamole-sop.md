# SOP Draft: XFCE + Guacamole GUI VM

Status: Oracle workflow documented after a successful manual installation.

This SOP describes two independent future cloudify packages for an Ubuntu 24.04 Incus guest and a Guacamole gateway.

The concrete host, instance, hostname, and IP values below describe the proven oracle only.

They are not package constants or defaults.

Future recipes must receive deployment-specific values through environment variables, package configuration, or runtime discovery.

The tailnet device reclaimed the plain `guac-gui` name after the stale duplicate was deleted (verified 2026-09-07).
The RDP target is still represented by `CLOUDIFY_GUACAMOLE_RDP_HOST`, not a literal hostname.

The `xfce` package runs on the GUI guest.

The `guacamole` package runs on a Docker host and connects to any reachable RDP guest.

The packages must not silently manage Incus, Tailscale ACLs, or host firewall policy.

## E2E topology

```text
Windows or tailnet client
        |
        | HTTPS or HTTP during oracle validation
        v
cloudstation: Guacamole Docker stack
  guacamole -> guacd -> RDP/TCP 3389
        |
        | Tailscale ACL: tag:node -> tag:incus
        v
cloudstation:guac-gui
  Tailscale 100.103.74.12
  XFCE + XRDP :3389
  SFTP/SSH :22
```

The working deployment used `cloudstation` as both the Incus host and Guacamole host.

The GUI guest was `cloudstation:guac-gui`.

The guest had local Incus address `10.48.192.16` and Tailscale address `100.103.74.12`.

The Guacamole host had Tailscale address `100.102.121.73` and exposed port `8080` only on that address.

The Guacamole connection must use the guest Tailscale address when the ACL permits the route.

The local Incus address is a diagnostic fallback, not the intended cross-node package default.

## Mandatory network preflight

Run this before either package.

### Incus host forwarding

On an Incus host whose UFW forward policy is `DROP`, allow Incus DHCP/DNS and outbound forwarding.

```bash
sudo ufw allow in on incusbr0
sudo ufw route allow in on incusbr0 out on eth0
```

These rules fixed guest DHCP and DNS on `cloudstation` and must survive a host reboot.

This host-level preparation does not belong inside the `xfce` or `guacamole` package.

### Tailscale identity and ACL

The working ACL grants `tag:node` access to `tag:incus`.

The gateway host must have the same identity tags as the known-good gateway:

```bash
ivps tag set cloudai tag:lighthouse tag:node
ivps tag set cloudstation tag:lighthouse tag:node
```

The GUI guest must have `tag:incus`.

Use `ivps tag get` and the guest Tailscale address to identify the correct device before changing a tag.

Do not edit Tailscale ACL JSON directly when the change is an ivps operation.

The critical working relationship is:

```text
cloudstation: tag:lighthouse,tag:node
cloudstation:guac-gui: tag:incus
ACL: tag:node -> tag:incus
```

A host tagged only as `tag:incus` cannot initiate the intended gateway-to-guest connection.

### Guest DNS and Tailscale

The guest must have working DHCP, DNS, and a default route before installing the desktop stack.

Tailscale must be installed and joined with the intended hostname and SSH capability before direct validation.

Do not put the Tailscale auth key in this SOP, a recipe, or a committed configuration file.

The current exposed key was accepted as a one-off risk and is not a pattern for rebuilds.

## Package 1: `xfce`

### Boundary

The package installs and configures the graphical desktop endpoint inside the Ubuntu 24.04 guest.

It owns XFCE, XRDP, Xorg integration, the GUI login account, the XFCE session command, Chrome, and the XRDP service.

It does not own Incus, Tailscale, Tailscale tags, ACLs, UFW forwarding, Guacamole, or the Guacamole connection record.

### Inputs

The future recipe should use these variables.

- `CLOUDIFY_XFCE_USER`, default `gui`.
- `CLOUDIFY_XFCE_USER_PASSWORD`, required for a new GUI account and declared in `.remote-vars`.
- `CLOUDIFY_XFCE_SESSION`, default `startxfce4`.
- `CLOUDIFY_XFCE_RDP_PORT`, default `3389`.
- `CLOUDIFY_XFCE_INSTALL_CHROME`, default `true`.
- `CLOUDIFY_XFCE_CHROME_URL`, default `https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb`.
- `PKG_VERIFY_TIMEOUT`, raised above the default when the guest starts slowly.

Passwords are supplied through the caller environment or package configuration and never written into this SOP.

The package should fail clearly when it must create the user and `CLOUDIFY_XFCE_USER_PASSWORD` is missing.

An existing user password must not be changed silently on a normal rerun.

### Install sequence

1. Install `xfce4`, `xfce4-goodies`, `xrdp`, `xorgxrdp`, and `dbus-x11` through the cloudify APT API or the shadowed `apt-get`.
2. Create `CLOUDIFY_XFCE_USER` when absent with a home directory and a non-root shell.
3. Set the password only when creating the account or when an explicit force/password-change operation requires it.
4. Keep the GUI account non-sudo by default.
5. Write `~/.xsession` for the GUI account with exactly the configured session command, initially `startxfce4`.
6. Ensure the GUI account owns its home and session file.
7. Add `xrdp` to `ssl-cert`.
8. Ensure `/etc/xrdp/key.pem` is readable by `xrdp` through the `ssl-cert` group and restart XRDP after correcting permissions.
9. Enable and start `xrdp`.
10. Download and install the official Chrome Stable `.deb` when `CLOUDIFY_XFCE_INSTALL_CHROME=true`.
11. Register Chrome as the GUI account’s HTTP, HTTPS, and HTML handler.
12. Register Chrome as XFCE’s preferred `exo-open` browser in `/home/<user>/.config/xfce4/helpers.rc` with `WebBrowser=google-chrome`.

The manual install proved that installing Chrome alone is insufficient because XFCE’s generic `xfce4-web-browser.desktop` launcher uses `exo-open`.

The user-level `helpers.rc` entry is required to prevent `Failed to execute default web browser`.

### Proven guest state

```text
/home/gui/.xsession                 startxfce4
/home/gui/.config/xfce4/helpers.rc  WebBrowser=google-chrome
/etc/xrdp/key.pem                   readable by xrdp through ssl-cert
xrdp                                enabled and active
XRDP                                listening on TCP 3389
Chrome                              installed for gui
```

The direct Windows client test used Thincast against `100.103.74.12:3389`.

That test proved XFCE and XRDP rendering before Guacamole was introduced.

### Install guard and data

The recipe must be idempotent.

A normal rerun must preserve the GUI account password, existing XFCE configuration, and Chrome profile.

A forced software reinstall may reinstall packages and rewrite only files owned by the recipe.

The recipe must not overwrite an existing user’s broader XFCE configuration without a backup or an explicit reset request.

`CLOUDIFY_CLEAR_DATA` must not delete the GUI home unless that destructive behavior is explicitly designed and documented.

### Verification

`pkg/xfce/verify.sh` should check only local endpoint health.

It should verify the following without relying on recipe-local variables:

- The configured user exists.
- The configured `.xsession` contains the configured session command.
- `xrdp` is active.
- The configured RDP port is listening.
- `/etc/xrdp/key.pem` is readable by the `xrdp` service account.
- Chrome exists when Chrome installation is enabled.
- XFCE’s preferred browser file points to Chrome when Chrome installation is enabled.

A local verification hook cannot prove that a remote Guacamole browser session renders.

The E2E gate must therefore include a real direct RDP session and a real Guacamole session.

## Package 2: `guacamole`

### Boundary

The package installs the official Apache Guacamole stack on a Docker host.

It owns the PostgreSQL database, `guacd`, the Guacamole web application, compose configuration, persistent data, and the initial database-backed administrator.

It does not own the GUI guest, XRDP, Incus, Tailscale, ACLs, UFW, Docker installation, or a public reverse proxy.

The package must depend on the existing cloudify `docker` package or fail clearly when Docker is absent.

### Inputs

The future recipe should use these variables.

- `CLOUDIFY_GUACAMOLE_DIR`, default `${HOME}/guacamole`.
- `CLOUDIFY_GUACAMOLE_VERSION`, default `1.6.0`.
- `CLOUDIFY_GUACAMOLE_POSTGRES_VERSION`, default `16`.
- `CLOUDIFY_GUACAMOLE_BIND`, required for a tailnet-only bind and set to the host Tailscale IPv4 in the oracle.
- `CLOUDIFY_GUACAMOLE_PORT`, default `8080`.
- `CLOUDIFY_GUACAMOLE_DB_NAME`, default `guacamole_db`.
- `CLOUDIFY_GUACAMOLE_DB_USER`, default `guacamole_user`.
- `CLOUDIFY_GUACAMOLE_DB_PASSWORD`, required secret and declared in `.remote-vars`.
- `CLOUDIFY_GUACAMOLE_ADMIN_USER`, default `rbc`.
- `CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD`, required secret and declared in `.remote-vars`.
- `CLOUDIFY_GUACAMOLE_RDP_HOST`, required target address, `100.103.74.12` in the oracle.
- `CLOUDIFY_GUACAMOLE_RDP_PORT`, default `3389`.
- `CLOUDIFY_GUACAMOLE_RDP_USER`, default `gui`.
- `CLOUDIFY_GUACAMOLE_RDP_PASSWORD`, required secret and declared in `.remote-vars`.
- `CLOUDIFY_GUACAMOLE_RDP_SECURITY`, default `any`.
- `CLOUDIFY_GUACAMOLE_RDP_IGNORE_CERT`, default `true` for the XRDP self-signed certificate.
- `CLOUDIFY_GUACAMOLE_ENABLE_SFTP`, default `false` until SFTP is separately validated.
- `CLOUDIFY_GUACAMOLE_SFTP_HOST`, default equal to the RDP host when enabled.
- `CLOUDIFY_GUACAMOLE_SFTP_PORT`, default `22` when enabled.
- `CLOUDIFY_GUACAMOLE_SFTP_USER`, default equal to the RDP user when enabled.
- `CLOUDIFY_GUACAMOLE_SFTP_PASSWORD`, required only when SFTP is enabled.
- `PKG_VERIFY_TIMEOUT`, raised for PostgreSQL initialization and Tomcat startup.

The package should use explicit pinned official images:

```text
guacamole/guacamole:1.6.0
guacamole/guacd:1.6.0
postgres:16
```

Never use `latest`, archived `oznu/guacamole`, Glyptodon/CentOS images, or a `user-mapping.xml` authentication shortcut.

### Compose topology

The compose project contains three services.

- `postgres` stores Guacamole data in a persistent named or host volume.
- `guacd` listens internally on `4822` and is not exposed on the host.
- `guacamole` connects to `postgres` and `guacd` by compose service names.

The host mapping is equivalent to:

```text
${CLOUDIFY_GUACAMOLE_BIND}:${CLOUDIFY_GUACAMOLE_PORT}:8080
```

The oracle used `100.102.121.73:8080:8080`, which kept the web UI off public interfaces.

A loopback default is safer for generic deployments; tailnet exposure must be an explicit bind variable.

The recipe must fail clearly when the requested host port is already occupied.

### Database initialization

Generate the PostgreSQL schema from the exact Guacamole image being deployed.

```bash
docker run --rm guacamole/guacamole:1.6.0 \
  /opt/guacamole/bin/initdb.sh --postgresql
```

The manual install exposed a PostgreSQL entrypoint permission trap.

A mode-600 `initdb.sql` mounted under `/docker-entrypoint-initdb.d` was unreadable by the PostgreSQL service account.

The reliable oracle procedure is:

1. Start PostgreSQL and `guacd`.
2. Wait until PostgreSQL accepts connections.
3. Pipe the schema through `psql` rather than relying on the mounted file.

```bash
docker compose exec -T postgres \
  psql -U guacamole_user -d guacamole_db -f - < initdb.sql
```

4. Apply the administrator update.
5. Start or restart Guacamole.
6. Wait for the web application to become healthy.

The PostgreSQL container has only the `guacamole_user` role because `POSTGRES_USER=guacamole_user` was used.

Run all database commands as `guacamole_user`; do not assume a `postgres` role exists.

`pgcrypto` is not required for the proven admin update path.

The schema is initialized only once for an empty data volume.

A partial initialization must be detected and handled rather than silently reseeded.

### Database administrator

The schema seeds the standard `guacadmin` entity.

The oracle renamed that entity to `rbc` and replaced its password hash.

The hash formula is exact and must not be changed:

```text
password_hash_bytes = SHA256(password + UPPERCASE_HEX_SALT_STRING)
password_salt_bytes = decode(UPPERCASE_HEX_SALT_STRING, hex)
```

Store the decoded bytes in PostgreSQL `bytea` fields.

Do not hash the password with raw salt bytes.

That incorrect first attempt produced HTTP 403 `Invalid login (rejected by postgresql)`.

The package must never print the password, salt, hash, or database password in logs.

Verify database authentication with a `POST /api/tokens` login request using the configured administrator credentials.

### RDP connection record

The connection record is created in Guacamole’s database-backed UI or through its API after the stack is healthy.

Use these RDP values:

```text
Protocol: RDP
Name: cloudstation GUI
Network hostname: 100.103.74.12
Network port: 3389
Username: gui
Password: <CLOUDIFY_GUACAMOLE_RDP_PASSWORD>
Security mode: any
Ignore server certificate: true
```

Leave clipboard-disable options unchecked for the oracle validation.

Do not fill Guacamole proxy parameters.

`guacd` is already the internal compose service at `guacd:4822`; the connection-level proxy fields are unnecessary here.

The fields named `security` and `ignore-cert` are stored as RDP parameters.

The saved oracle record contained `security=any` and `ignore-cert=true`.

The first failed attempt used `100.103.74.12` before cloudstation had the gateway tag required by the ACL.

The connection worked after `cloudstation` received exactly `tag:lighthouse` and `tag:node` through `ivps`.

### SFTP

SFTP is not part of the proven oracle gate yet.

When enabled, use the guest’s SSH service on port `22` and the same GUI account only after a separate transfer test.

Do not claim file transfer support in the package verification hook until upload and download have both been validated.

### Install guard and data

The compose files and generated `.env` are software/configuration and may be regenerated.

The PostgreSQL data volume is persistent data and must not be deleted during a normal reinstall.

The recipe must skip an existing healthy deployment unless `CLOUDIFY_FORCE` or `CLOUDIFY_CLEAR_DATA` is set.

`CLOUDIFY_CLEAR_DATA` may remove the PostgreSQL volume only after an explicit destructive confirmation path.

Changing `POSTGRES_PASSWORD` after the database is initialized does not reinitialize or safely rotate the database credential.

Document password rotation as a database operation, not as a compose environment change.

Use backups before forceful database changes.

### Verification

`pkg/guacamole/verify.sh` must be self-contained and use exported variables or on-disk configuration only.

It should verify the following:

- The compose project exists at the configured directory.
- PostgreSQL is running and healthy.
- `guacd` is running.
- Guacamole is running and healthy.
- The configured bind address and port answer HTTP.
- The configured administrator can obtain an API token.
- The configured database connection exists with the expected RDP hostname and port.

The final E2E verification must open the connection in a real Guacamole browser session.

That session must render XFCE, accept keyboard input, and open Chrome.

The verification plan must later add clipboard both ways, Alt-Gr, reconnect, multiple Firefox or Chrome tabs, and performance checks.

## Cloudify package layout

The intended future layout is:

```text
pkg/xfce/
├── init.sh
├── verify.sh
├── README.md
└── .remote-vars

pkg/guacamole/
├── init.sh or install.sh + configure.sh
├── verify.sh
├── README.md
└── .remote-vars
```

`xfce/.remote-vars` should declare `CLOUDIFY_XFCE_USER_PASSWORD`.

`guacamole/.remote-vars` should declare the database, administrator, RDP, and optional SFTP secret names.

Values belong in the caller environment or `~/.config/cloudify/pkgs/<pkg>.yaml`, never in the repository.

The Guacamole package may benefit from the install/configure split because image installation, database initialization, connection configuration, and secret rotation have different lifecycles.

The two packages must remain independently installable.

Guacamole must not depend on `xfce`, because its RDP target may be any existing RDP server.

An optional later orchestration package may install both and pass their configuration, but that is not part of these package boundaries.

## Oracle acceptance gate before implementation

The manual workflow is not considered package-ready until it passes a clean rebuild.

1. Record the Incus guest creation command and all non-secret host preflight commands.
2. Destroy and recreate the GUI guest.
3. Reapply network, Tailscale identity, and `tag:incus` through the documented ivps workflow.
4. Install the XFCE package candidate from a clean guest.
5. Prove direct XRDP rendering and Chrome launch.
6. Recreate the Guacamole PostgreSQL, `guacd`, and Guacamole stack from an empty data volume.
7. Apply the schema through the tested stdin pipeline.
8. Create the database-backed administrator without a default password.
9. Create the RDP connection without proxy parameters.
10. Prove Guacamole-to-XRDP rendering through the tailnet ACL.
11. Record any rebuild failure as a recipe or SOP defect and fix it before declaring the oracle complete.
12. Only after this gate passes, implement `pkg/xfce` and `pkg/guacamole` and add integration tests in the Incus test environment.

## Known unresolved items

- SFTP upload and download remain unvalidated.
- TOTP remains a post-basic-connectivity hardening step.
- Guest firewall restrictions for XRDP should be explicitly confirmed.
- Guest DNS persistence after reboot should be confirmed.
- HTTPS tailnet-only exposure through `ivps expose-private` remains separate from the Guacamole package’s basic HTTP oracle.
- The existing exposed Tailscale auth key remains accepted for this installation but must not be copied into future automation.

## Session 2026-08-31 learnings (durable rebuild facts)

These were found while working the live oracle; they should shape a rebuild and the future packages.

### Guacamole letterbox: set `resize-method=display-update`

The GUI was letterboxed (black strips top/bottom) because the connection used Guacamole's default fixed resolution and the client scaled it to the browser preserving aspect. Fix: set the RDP connection parameter `resize-method=display-update` (guacamole_connection_parameter). The remote session then tracks the browser window size, so it fills the client with no letterbox. The clue was that right-clicking the strip showed the *browser* menu, not XFCE — i.e. it was client-side, not desktop-side. This belongs in the Guacamole package's connection record.

### XFCE GTK/icon theming is unrenderable under xrdp (parked)

xorgxrdp's virtual X server lacks the XI2 (X Input 2) extension, so `xfsettingsd` never registers the `_XSETTINGS_S0` XSETTINGS manager and GTK apps receive no theme — even with the config set correctly (Arc/Papirus). Confirmed not a config error (config is correct, rendering just doesn't happen). Receipts: Launchpad #354830 ("no gtk theme" when XI absent via xrdp/VNC), Xfce forums #8112 and #8603. A rebuild should NOT chase this; the GTK theme is cosmetic. If theming is required, the path is a non-xrdp display (wlroots/VNC), which is a larger change.

### Guest auto-tiling: Cortile (works on top of xfwm4)

Cortile (Go binary, v2.5.2, MIT) provides dynamic auto-tiling on top of Xfwm with no keybinding needed — windows tile automatically on open. Install from GitHub releases (`cortile_<ver>_linux_amd64.tar.gz`), verify the SHA256 against `cortile_<ver>_checksums.txt`, place the binary in `/usr/local/bin`, and add an XDG autostart entry (`~/.config/autostart/cortile.desktop`). This is the intended tiling solution for the XFCE guest (avoid i3/WM swap).

### GUI login account may be sudo (instance-specific, not the package default)

The live instance enables `sudo` for the `gui` user (`usermod -aG sudo gui`), which deviates from the package design's "non-sudo by default". Sudo is gated per deployment; the package should keep the non-sudo default and treat sudo as an opt-in variable. The `gui` password is recoverable from the Guacamole connection record (the RDP password equals the system password, since xrdp authenticates against PAM).

### Tailscale duplicate-hostname gotcha

Two Incus containers that share an internal hostname (e.g. `guac-gui`) will both join Tailscale with that name; Tailscale names them `guac-gui` and `guac-gui-1`, and MagicDNS serves the older first — so `ssh guac-gui` can hit the wrong box. Fix: delete the stale instance WITH its tailnet device (`ivps delete <node>:<name>` removes both), then rename the survivor to the base name in the Tailscale console (done 2026-08-31 for guac-gui, verified 2026-09-07). The container's own hostname is unaffected; only the DNS name is.

### Other cosmetic post-install tweaks applied on the oracle

- Wallpaper set to a user image (`/usr/share/backgrounds/modern.png`); desktop icons hidden (`xfce4-desktop:/desktop-icons/style=0`); xfwm compositing off (`use_compositing=false`). These are taste/performance, not requirements for a rebuild.
