# Authoring a Cloudify Package

A package is a directory under `pkg/<name>/`.

> **Path note:** recipes currently live in `~/PROJECTS/PROD/cloudify/pkg/`; a future refactor moves them to `$XDG_DATA_HOME/cloudify/pkg/`. Author portably — the `pkg_*` API isolates you from the path, so recipes won't need rewriting when it moves.

## Layout

```
pkg/<name>/
├── init.sh        # REQUIRED — install recipe
├── verify.sh      # OPTIONAL — defines pkg_verify() (see below)
└── @<tag>         # OPTIONAL — empty tag file: @default, @web, #linux, ...
```

Create the dir + `init.sh`, then `cloudify install <name>` to test locally.

## Recipes

Plain bash, run with `set -Eeuo pipefail`. The `pkg_*` API is auto-available (no sourcing). Runs in the target env (local or remote via SSH), so `curl`, `apt-get`, `bash` are directly available. `sudo`, `apt-get`, `git` are auto-wrapped (passwords, idempotency, auth) — call them plainly.

**APT:**
```bash
#!/usr/bin/env bash
# entr — run commands when files change
apt-get install -y entr
```

**GitHub release (auto-detects arch):**
```bash
#!/usr/bin/env bash
# bat — better cat
pkg_install_release bat "sharkdp/bat"
```

**With a dependency:**
```bash
#!/usr/bin/env bash
# my-tool — needs git first
pkg_depends git
curl -fsSL https://example.com/install.sh | bash
```

## API functions (`pkg_*`)

| Function | Purpose |
|----------|---------|
| `pkg_apt_install <pkg...>` | install apt packages (skips installed) |
| `pkg_apt_update [--force]` | update apt cache |
| `pkg_apt_repository <repo>` | add apt repository |
| `pkg_depends <pkg...>` | install cloudify packages (falls back to apt) |
| `pkg_install_release <name> <repo>` | install latest GitHub release |
| `pkg_backup <path>` | backup file/dir (rotated, up-to-5) |
| `pkg_restore <path>` | restore from backup |
| `pkg_in_startuprc <line>` | add line to ~/.bashrc (deduped) |
| `PKG_DEBUG <msg>` | debug print when `DEBUG=true` |

`pkg_depends` checks for a cloudify recipe (`pkg/<name>/init.sh`) first; if none, falls back to `pkg_apt_install`. So `pkg_depends git jq bat` works for mixed cloudify/apt deps.

## Install guards (stateful packages)

Thin packages (apt/binary only: `bat`, `fd`, `jq`) need no guards. **Stateful** packages (config, data dirs, containers, DBs) MUST guard against redundant installs and data loss.

- **Software** (binaries, venvs, images, apt pkgs) — overwritten on forced reinstall.
- **Data** (user config, DBs, sessions, uploads, API keys) — preserved unless `--clear-data`.

The framework sets these (read, don't set): `CLOUDIFY_FORCE` (set for explicitly dispatched packages; unset for `pkg_depends` deps) and `CLOUDIFY_CLEAR_DATA` (set by `--clear-data`; implies FORCE; wipes persistent data only).

**Pattern — after `pkg_depends`, before install work:**

```bash
pkg_depends <deps>

# --- Install guard ---
if <already_installed> \
   && [[ -z "${CLOUDIFY_FORCE:-}" ]] \
   && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "<Pkg> already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Clear data if requested ---
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    log_info "Clearing <pkg> data..."
    rm -rf <data_dir>
fi

# ... install software below ...
```

- `<already_installed>` — fastest reliable check: `command -v bin`, `-f config`, or `-d dir`.
- `<data_dir>` — persistent user data (e.g. `~/.hermes`). Files the recipe *generates* (`docker-compose.yml`, `.env`) are NOT data — they regenerate every install.

## Verification (`verify.sh`) — optional

Makes `cloudify install` block until healthy. Sourced in a **clean subshell** (exported env + on-disk state only — never recipe locals) by a retry loop after the recipe runs.

```bash
# pkg/hermes-dashboard/verify.sh
pkg_verify() {
    local port="${HERMES_DASHBOARD_PORT:-9119}"
    systemctl --user is-active hermes-dashboard >/dev/null 2>&1 || return 1
    curl -sf --max-time 5 "http://127.0.0.1:${port}" >/dev/null || return 1
}
```

**Hard rules:**
1. **Clean subshell** — read inputs from env vars (`pkgs/<pkg>.yaml`) or config files the recipe wrote, never recipe locals.
2. **No hardcoded endpoints** — every `host:port` from an env var or config-file read. Keeps a package deployable in same-container AND separate-container modes.
3. **Self-contained, standard commands only** — no recipe-defined helpers; works identically in install+verify and verify-only paths.
4. **Idempotent** — called repeatedly by the retry loop.

**Deep verification** runs after every package including `pkg_depends` deps. Authoring contract for packages that rewire a dependency:
- **(a) Parent overrides a dep via an env var** → declare it in `pkgs/<parent>.yaml` (forwarded parent-priority). Don't set it in the recipe body (that runs after the dep is verified).
- **(b) Parent hardcodes a rewire** → the parent's `verify.sh` asserts it; the dep's `verify.sh` must NOT.

Timeout via `pkgs/<pkg>.yaml`: `PKG_VERIFY_TIMEOUT: 120`.

## Tags

```bash
touch pkg/mytool/@default      # auto-installed with `cloudify install default`
touch pkg/mytool/@web          # grouping
touch pkg/mytool/#linux        # platform filter
```

## Workflow

1. `mkdir pkg/<name>` + write `pkg/<name>/init.sh` (minimal first).
2. Add `verify.sh` if it runs a service; add tags if wanted.
3. Set package vars: `~/.config/cloudify/pkgs/<name>.yaml`.
4. **Test locally:** `cloudify install <name>`.
5. **Test remotely:** `git push`, then `cloudify --on <host> install <name>`.
6. On failure, read `/tmp/cloudify/logs/<ts>.log`, fix, push, re-test.

## Testing (TDD)

Cloudify's SDLC is TDD inside an Incus container. For a new package add `tests/integration/package-<name>.bats`:

```bash
#!/usr/bin/env bats
TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install mypkg succeeds" {
    run cloudify --on "$TEST_HOST" install mypkg
    [ "$status" -eq 0 ]
}

@test "mybin exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v mybin'
    [ "$status" -eq 0 ]
}
```

```bash
task test-integration:mypkg   # single package (push first)
task test                     # unit + integration
task lint                     # shellcheck
```

Integration tests SSH into the container and pull from GitHub → **push first**. Requires Incus + `ivps` + a running `cloudai:cloudify` container (see cloudify's README "Developer Guide").
