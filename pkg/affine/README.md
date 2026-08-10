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
