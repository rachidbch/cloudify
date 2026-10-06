# affine

[Affine](https://github.com/rachidbch/affine) — clean-room replica of Linear's
MCP server (oracle mcp.linear.app/mcp), built by a pi agent under a PRD +
review-gate workflow. Streamable HTTP MCP server, multi-user, multi-team,
multi-project.

## Install

```bash
cloudify --on <host> install affine
```

Stack:

- **node** (mise, LTS) → runs `bin/affine-server.mjs` with `npm ci` deps
  (@libsql/client, zod). Needs Node >= 20.11 (`import.meta.dirname`).
- **git** → clones the **private** repo `rachidbch/affine`; the cloudify git
  shadow injects your stored GitHub credentials, no token in the recipe.
- Runs as a **systemd user service** (linger enabled) on port 8787, all
  interfaces — gate access at the network boundary (Tailscale Service /
  `tailscale serve`), same posture as piface.

## Knobs (declared in `.remote-vars`; the server reads exactly these env names)

- `AFFINE_PORT` (default 8787) — listen port, baked into the systemd user unit.
- `AFFINE_RATE_LIMIT` (default 100) / `AFFINE_RATE_WINDOW_MS` (default 60000) — rate limiting.
- `AFFINE_DIR` (default `~/PROJECTS/affine`) / `AFFINE_DB` (default `<dir>/data/state.db`) — locations.
- `AFFINE_LINEAR_API_KEY` (optional, secret) — when set, `configure` writes it to `<dir>/.linear-api-key` (0600). Compatibility door: clients bearing the real Linear API key get an anonymous, non-admin context. Unset leaves any existing file untouched (removing a credential is explicit).

`configure.sh` converges files only (unit + key file, restart, expect 401). The sqlite database is domain data and is never touched by cloudify.

## Uninstall

```bash
cloudify --on <host> uninstall affine              # stop + disable the unit, remove it
cloudify --on <host> uninstall affine --clear-data # additionally wipe <AFFINE_DIR> (source + data + master token)
```

Plain teardown stops the service but keeps `data/` (the external backup
process owns it) and the clone (install rebuilds it). Idempotent: an already-
absent install succeeds with nothing to do. Dependencies (git, mise, node) are
never removed.

## Backup contract (owned by an EXTERNAL process; cloudify never backs up or restores)

**What to back up:** `<AFFINE_DIR>/data/` in its entirety — `state.db` with its `-shm`/`-wal` siblings. That one directory is the complete soul of the deployment: users, teams, projects, credentials.

**Watch for — backup:** the database is live sqlite; a plain `cp` of a writing database can tear. Use an online snapshot (`sqlite3 data/state.db ".backup <dest>"`) or a stop → copy → start window.

**Credentials are not bucket material (the rule: back up irreplaceable state, rebuild what is recorded):**

- `data/admin-token.json` (if ever present) is the master credential. Its backup is the operator's offline copy — that is the point of the first-boot ritual. The bucket must never hold a second live copy: encrypt or exclude.
- `.linear-api-key` is configuration, not state: its home is cloudify's secret store (`AFFINE_LINEAR_API_KEY`), from which `configure` regenerates the file. If a hand-placed key file exists on any machine, the fix is to declare it (`vars set` + reconfigure) — never to back up the stray file.

**Watch for — restore:** fresh instance → `cloudify --on <host> install affine` → stop the service → replace `data/` with the snapshot → start → an unauthenticated POST must answer 401. Do not restore the git clone, `node_modules`, or the unit file — the recipe and the recorded values rebuild those.

## First boot — the MASTER token (read this)

On a fresh `data/`, the server mints the **master** identity (`role: master`)
and writes its token to `data/admin-token.json` (0600). The recipe prints the
token at the end of the install:

1. **Mint the first admin**: `create_user { name: <admin>, role: "admin" }`
   with the master token (the only credential that can create admins).
2. **Store the master token offline** (e.g. printed, in a safe). It is used
   only for emergencies (e.g. leaked-admin recovery: delete the leaked admin,
   mint a replacement).
3. A non-master admin **cannot** create admins (`only master can create
   admin users`); the master itself cannot be deleted or demoted by anyone.

`--clear-data` wipes `state.db` + the token: a **new** master is minted and
the old token dies. The recipe prints the new one.

## Configuration

Vars live in `~/.config/cloudify/pkgs/affine.yaml`:

| Var | Default | Description |
|-----|---------|-------------|
| `AFFINE_PORT` | `8787` | Server port |
| `AFFINE_DIR` | `~/PROJECTS/affine` | Source checkout + data dir |

## Optional: .linear-api-key

`$AFFINE_DIR/.linear-api-key` (0600) enables live-oracle parity checks
(`search_documentation` proxy etc.). Without it the server runs fully; the
oracle-gated paths degrade. Not required for a staged deployment.

## Verify

`verify.sh` asserts the service is active and unauthenticated `POST /mcp`
answers 401 (server up, auth layer enforced).

## Docs

Spec truth lives in the repo: `PRD.md` (governing), `ADR.md` (decisions
001-019), `ROADMAP.md` (roadmaped/parked/BLOCKED-on-F2), `REPORTS.md`
(review-gate verdicts), `MIGRATION_DECISIONS.md` (migration ledger).
