# zitadel

[Zitadel](https://zitadel.com) - the identity anchor for SecureVault
(OIDC issuer, device-flow login, machine PATs). Official v4 compose stack in
external-TLS mode: traefik -> zitadel-api (start-from-init) + zitadel-login
(Login v2) -> postgres. TLS terminates OUTSIDE the stack; traefik publishes
127.0.0.1 only.

## Install

```bash
cloudify --on <host> install zitadel
```

Requires `CLOUDIFY_ZITADEL_DOMAIN` (the public https name). Secrets are
generated on first install and persisted in `~/zitadel/.env` (0600); supply
your own via env or `~/.config/cloudify/pkgs/zitadel.yaml` if you prefer.

## Configuration

| Var | Default | Meaning |
|-----|---------|---------|
| `CLOUDIFY_ZITADEL_DOMAIN` | required | public https name, e.g. `zitadel.<tailnet>.ts.net` |
| `CLOUDIFY_ZITADEL_VERSION` | `v4.19.3` | pinned upstream tag (api + login images) |
| `CLOUDIFY_ZITADEL_BIND` | `127.0.0.1` | traefik bind (keep local; the edge terminates TLS) |
| `CLOUDIFY_ZITADEL_PORT` | `8080` | traefik port on the host |
| `CLOUDIFY_ZITADEL_MASTERKEY` | generated (32) | encrypts Zitadel data at rest; immutable after init |
| `CLOUDIFY_ZITADEL_SESSION_COOKIE_SECRET` | generated (32) | signs Login v2 session cookies |
| `CLOUDIFY_ZITADEL_POSTGRES_PASSWORD` | generated (32) | postgres superuser password |
| `CLOUDIFY_ZITADEL_BOOTSTRAP_MACHINE` | `securevault-bootstrap` | FirstInstance machine user name |
| `CLOUDIFY_ZITADEL_PAT_EXPIRATION` | `2099-01-01` | bootstrap + login-client PAT expiry |

Secrets must not contain single quotes or control chars (payload landmine).

## Bootstrap PAT (automation unlock)

At instance creation Zitadel's FirstInstance job writes an IAM_OWNER machine
PAT to the shared bootstrap volume; install copies it to
`~/zitadel/bootstrap.pat` (0600). Consume it headlessly:

```sh
PAT=$(ssh <host> 'sudo cat ~/zitadel/bootstrap.pat')
curl -H "Authorization: Bearer $PAT" https://<domain>/management/v1/iam
```

Rotate/revoke from the Zitadel console; a fresh PAT comes only with a fresh
instance (`--clear-data`).

## Tailnet exposure (the TLS edge)

On an ivps instance the edge is Tailscale Serve (auto-TLS, tailnet-only):

```bash
ivps expose-direct <node>:zitadel 8080
# -> https://zitadel.<tailnet>.ts.net
```

Zitadel answers `Instance not found` if the Host does not match
`CLOUDIFY_ZITADEL_DOMAIN` - they must be the same name.

## Lifecycle

- `cloudify configure zitadel` - converge config, restart changed services.
- Upgrade: bump `CLOUDIFY_ZITADEL_VERSION`, then `cloudify configure zitadel`
  (compose pulls and recreates; volumes persist).
- `cloudify install zitadel` (no FORCE) - idempotent skip while running.
- `--clear-data` - destroy the instance and reinstall fresh (new PAT, new
  masterkey unless supplied).
- `cloudify uninstall zitadel` - full teardown, volumes included.

## Service management

```sh
sudo docker compose -f ~/zitadel/docker-compose.yml ps
sudo docker compose -f ~/zitadel/docker-compose.yml logs zitadel-api
```

## Field notes (empirically proven, 2026-09-30)

- Zitadel image is distroless: no shell, no `cat` - read the PAT from the
  volume's host mountpoint, never `compose exec`.
- `CLOUDIFY_ZITADEL_DOMAIN` must equal the serve hostname byte-for-byte,
  else Zitadel answers "Instance not found". Tailscale Serve preserves
  Host and its X-Forwarded-Proto is trusted via `ZITADEL_TRUSTED_IPS`.
- Device codes expire in 5 minutes; a first login (TOTP enrollment +
  password change) can outlast them - expect one retry, not a bug.
- Console (admin UI) is at `/ui/console`; `/` is the Login app's session
  home by v4 design.
- Apps default to opaque access tokens; consumers verifying offline via
  JWKS must set `accessTokenType: OIDC_TOKEN_TYPE_JWT` (see SecureVault's
  scripts/zitadel-provision.py).
- Instance-level roles (IAM_OWNER) are granted via `POST /admin/v1/members`,
  not project grants.
- Machine-only FirstInstance creates no default admin human (good).

## Design provenance

Official upstream compose (external-TLS mode) + docs, revalidated 2026-10:
https://zitadel.com/docs/self-hosting/deploy/compose ,
https://zitadel.com/docs/self-hosting/manage/tls_modes ,
deploy/compose/AGENTS.md in github.com/zitadel/zitadel. See
plans/zitadel-pkg.md.
