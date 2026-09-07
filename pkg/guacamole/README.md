# pkg/guacamole

Apache Guacamole gateway on a Docker host: guacamole webapp + guacd + postgres
via docker-compose, with an initial database-backed administrator and an RDP
connection record, created through the REST API.

Proven oracle: `.drafts/xfce-guacamole-sop.md` (Package 2). Design +
non-breakage rationale: `plans/guacamole-pkg-description.md` and
`plans/guacamole-pkg-plan.md`.

## Boundary

Owns: the postgres database, guacd, the guacamole webapp, compose
configuration, persistent data volume, initial admin, RDP connection record.

Does NOT own: the RDP GUI guest, Incus, Tailscale tags/ACLs, UFW forwarding,
Docker installation (depends on `pkg/docker`), a public reverse proxy, or
HTTPS. SFTP and TOTP are out of scope (unvalidated; see the SOP).

Guacamole does not depend on `pkg/xfce`: any reachable RDP server is a valid
connection target.

## Install

```bash
cloudify --on <docker-host> install guacamole
cloudify --on <docker-host> configure guacamole   # reapply config / rotate target
cloudify --on <docker-host> verify guacamole      # verify-only
```

Split package (ADR-008): `install` = dep + guard + provision + one-time schema
init + admin; `configure` = rewrite config, start stack, ensure connection.
Both phases run on `install`.

## Configuration

Secrets and deployment values arrive via the caller environment or
`~/.config/cloudify/pkgs/guacamole.yaml` (never in the repo). Names forwarded
remotely (`.remote-vars`): `CLOUDIFY_GUACAMOLE_DB_PASSWORD`,
`CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD`, `CLOUDIFY_GUACAMOLE_RDP_PASSWORD`,
`CLOUDIFY_GUACAMOLE_RDP_HOST`.

Configuration values (env or per-pkg yaml):

- ``CLOUDIFY_GUACAMOLE_DIR`` - default `${HOME}/guacamole` - compose project dir, `.env` mode 600
- ``CLOUDIFY_GUACAMOLE_VERSION`` - default `1.6.0` - pinned `guacamole/*` image tags
- ``CLOUDIFY_GUACAMOLE_POSTGRES_VERSION`` - default `16` - pinned `postgres` tag
- ``CLOUDIFY_GUACAMOLE_BIND`` - default `127.0.0.1` - loopback default; tailnet exposure is an explicit bind (e.g. the host's Tailscale IPv4)
- ``CLOUDIFY_GUACAMOLE_PORT`` - default `8080` - host port; install fails if already in use
- ``CLOUDIFY_GUACAMOLE_DB_NAME`` - default `guacamole_db` - postgres database
- ``CLOUDIFY_GUACAMOLE_DB_USER`` - default `guacamole_user` - postgres role (no `postgres` superuser exists)
- ``CLOUDIFY_GUACAMOLE_DB_PASSWORD`` - default required - secret
- ``CLOUDIFY_GUACAMOLE_ADMIN_USER`` - default `rbc` - replaces the seeded `guacadmin` at init
- ``CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD`` - default required - secret, used for the API hash at init
- ``CLOUDIFY_GUACAMOLE_RDP_HOST`` - default required - connection record target (e.g. guest Tailscale IP)
- ``CLOUDIFY_GUACAMOLE_RDP_PORT`` - default `3389` - 
- ``CLOUDIFY_GUACAMOLE_RDP_USER`` - default `gui` - 
- ``CLOUDIFY_GUACAMOLE_RDP_PASSWORD`` - default required - secret, stored in the connection record
- ``CLOUDIFY_GUACAMOLE_CONNECTION_NAME`` - default `GUI` - display name of the RDP connection



## Verification

`pkg_verify` (self-contained, retried until `PKG_VERIFY_TIMEOUT`, default 30s -
raise to ~300 for first boot):

- compose project exists, postgres/guacd/guacamole all running
- webapp answers HTTP on the configured bind/port
- administrator obtains an API token
- the connection record exists with the configured RDP host/port

It reads state from the on-disk `.env`, so it also works on remote verify-only
runs that forward no package vars. A local endpoint hook cannot prove a real
Guacamole browser session renders; that E2E gate needs the GUI guest and is
tracked in the SOP acceptance gate.

## Guards and data

- Idempotent: schema init and admin creation run once (marker file + partial-
  init detection; a crashed init is repaired, never silently reseeded).
- Rerun preserves the database; secrets not re-exported are kept from the
  previous `.env` (export a secret to rotate it).
- `cloudify install guacamole --clear-data` drops the postgres volume
  (destructive, no rollback - backup first).

## Gotchas

- Secrets (DB/admin/RDP passwords) must not contain single quotes or control
  characters: cloudify bakes forwarded values into the payload in single
  quotes (mechanism landmine L1).
- Admin password rotation is a database operation (the hash formula in the
  SOP), not a compose/env change - changing `CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD`
  on a rerun updates the stored `.env` but NOT the existing DB hash. Fresh
  installs or `--clear-data` apply it.
- RDP password stored in the connection record is only (re)written when the
  record is created or updated; the API may mask it, so a password-only change
  requires deleting the record or changing a compared field (host/port/user/
  security/ignore-cert/resize-method).
- Changing `CLOUDIFY_GUACAMOLE_DB_PASSWORD` after init does not reinitialize
  or safely rotate the database credential - treat as a DB operation.
- `--on` remote hosts run code from GitHub master: push before testing.
- A non-default `CLOUDIFY_GUACAMOLE_DIR` must come from per-pkg yaml or
  deployment vars to reach a remote host (not a `.remote-vars` name).
