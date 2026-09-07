# Plan: pkg/guacamole (per CRITICAL GATE — plan + non-breakage argument)

Status: pending explicit human consent. Grounded in plans/guacamole-pkg-description.md (the
gate's description artifact, code-read) + .drafts/xfce-guacamole-sop.md (oracle facts) +
precedent reads (pkg/k3s-server split, pkg/docker, tests/run-integration.sh).

## Scope

New files ONLY under `pkg/guacamole/` + one integration test file. Nothing in cloudify/ router,
lib/, shadows, existing pkg behavior, tests helpers.

- `pkg/guacamole/install.sh` — split-pkg install phase (ADR-008, k3s-server model)
- `pkg/guacamole/configure.sh` — run phase: rewrite software config, restart, ensure admin+connection
- `pkg/guacamole/verify.sh` — self-contained pkg_verify()
- `pkg/guacamole/.remote-vars` — secret NAMES: CLOUDIFY_GUACAMOLE_DB_PASSWORD,
  CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD, CLOUDIFY_GUACAMOLE_RDP_PASSWORD
- `pkg/guacamole/README.md`
- `tests/integration/package-guacamole.bats`

## Non-breakage argument

The description artifact §5 proves: adding only pkg/<name>/ files cannot alter any mechanism —
package discovery is data-driven over pkg/ dirs; forwarding is driven by files inside the new
pkg dir; shadows activate by name at router startup (new pkg = new consumer, no loader change);
verify is opt-in by file presence. Every landmine L1-L11 from the artifact maps to a design rule
below; the recipe touches no mechanism code, so existing invariants are preserved by
construction. Pushed to GitHub before any --on test (remote hosts run repo code).

## Package design (vars from SOP §Inputs, defaults refined)

Defaults per SOP. BIND default 127.0.0.1 (loopback safer; tailnet = explicit var). PORT 8080.
VERSION 1.6.0, POSTGRES 16. New non-secret var CLOUDIFY_GUACAMOLE_CONNECTION_NAME (default
"GUI" — display name of the RDP connection record).

Secret transport: three names in .remote-vars; values from caller env or pkgs/guacamole.yaml
(first-write-wins, env > yaml). .env written mode 600 in $CLOUDIFY_GUACAMOLE_DIR
(default ${HOME}/guacamole) holding POSTGRES_* + GUACAMOLE_* for compose AND the admin/RDP
values as extra keys (compose ignores unknown keys; recipe+verify source the same file).
Never echoed to stdout/logs.

## Design rules (landmine-driven)

- R1 (L1): secrets must not contain `'` or control chars (framework bakes them single-quoted).
  Validated + documented. Admin hash salt generated ON the host (hex, no raw-bytes hashing).
- R2 (L2): NEVER pipe data through `sudo` into a stdin-reading command. Container ops use
  `sudo docker ...` only for non-stdin commands (pull, cp, compose up/down/ps, exec). The
  initdb schema (100KB+) is docker cp'd into the postgres container then `sudo docker exec`
  psql `-f /tmp/initdb.sql` — no stdin, any size. Mirrors the oracle's stdin pipeline result
  without the shadow trap. `sudo docker` (not bare docker) because docker-dep install adds the
  group only for NEW sessions (docker pkg's own newgrp warning); bare docker after dep would
  fail on first-run in-session.
- R3 (L3): recipe uses pkg_apt_install/pkg_apt_update/pkg_depends + shadows only; never
  command-sudo-apt / command-git. docker dependency pulled via pkg_depends docker.
- R4 (L4): no interactive reads; all config from env/.env/files.
- R5 (L5): every .remote-vars name has a caller value or yaml fallback; required secrets die
  with a clear message when missing (SOP: fail clearly when creating user / missing password).
- R6 (L6): verify.sh reads state from disk (.env, compose ps, HTTP, API) + defaults; never
  recipe-local vars, never hardcoded host:port.
- R7 (L7): verify-only remote forwarding is absent → verify.sh must work from .env + defaults
  alone (it does: .env holds bind/port/admin/RDP). PKG_VERIFY_TIMEOUT default raised via
  pkg yaml or caller (300 first boot).
- R8 (L8): split phases share one subshell; DB-init is guarded on DISK STATE (marker file +
  volume non-empty), not on phase. configure.sh is re-runnable and never wipes data.
- R9 (L9): install guard AFTER pkg_depends docker; healthy-check = compose file exists +
  project up (docker compose ls). CLEAR_DATA drops the postgres volume + marker BEFORE
  software rewrite (data wipe only under explicit --clear-data, per SOP destructive path).

## Phase semantics

install.sh: guard → docker dep (pkg_depends) → guard after dep → dirs + .env (600) +
compose.yml (pinned images: guacamole/guacamole:1.6.0, guacd:1.6.0, postgres:16) → port-conflict
fail check (ss) → compose up -d postgres+guacd → wait pg_isready → initdb.sql via
`docker run --rm <image> initdb.sh --postgresql > host file` → docker cp + exec psql -f
(only when volume empty + no marker) → admin SQL (rename guacadmin → ADMIN_USER + hash from
hex salt; exact formula, bytea) → compose up -d full stack → wait healthy → ensure connection
record via API (login POST /api/tokens, GET/POST connections, RDP params: hostname/port/
username/password, security=any, ignore-cert=true, resize-method=display-update; upsert by
name, no proxy fields) → verify (unless --no-verify).

configure.sh: rewrite .env + compose.yml from current vars (software only), compose up -d,
wait healthy, ensure admin+connection via API (idempotent, no data touch). Guard-free.

verify.sh pkg_verify(): compose project dir exists; compose ps shows postgres healthy /
guacd / guacamole running; bind:port answers HTTP from .env values; admin API token login
succeeds (creds from .env); connection record exists with expected RDP host/port (API,
from .env). Retried by framework until PKG_VERIFY_TIMEOUT.

## Test plan (disposable targets only — production cloudstation untouched)

1. Unit-ish: shellcheck (task lint) + fixture-env/fixture-split conventions respected.
2. Integration: tests/integration/package-guacamole.bats run via run-integration.sh in a
   fresh itest-base snapshot of cloudai:cloudify (has nesting → docker works). Installs the
   pkg (docker dep pulled first-run → proves dep path), bind 127.0.0.1:18080, asserts
   compose healthy + HTTP + token + connection. Fixture exports the three secrets.
3. Real --on smoke on a NEW scratch container (cloudai or cloudstation, disposable) is the
   eventual end-to-end proof with a real RDP guest — deferred to the xfce pkg phase which
   provides the GUI target; guacamole alone proves up to connection-record level (its
   boundary per SOP).
4. Push to GitHub before integration (remote runs repo code).

## What I will NOT do

- No change to cloudify/lib/shadows/router/README of mechanisms.
- No test on cloudstation's live guacamole stack; its port 8080/volume stay untouched.
- No SFTP/TOTP/HTTPS claims (SOP known-unresolved; not in scope).
- No destructive op on any real host.
