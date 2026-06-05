# Cloudify

## Conventions

- **Token efficient** — min tokens, max signal. Especially in .md files.
- **`--on <host>`** comes BEFORE the action verb: `cloudify --on host install pkg`
- **HISTORY.md** — append-only log of all actions/outcomes. Never edit or delete entries.

## Project

Bash-based host provisioning and package management for Ubuntu/Debian. Two components:

1. **GitHub repo** (`github.com/rachidbch/cloudify`) — CLI router (`cloudify`) + `lib/` modules + `pkg/` recipes + `tests/`
2. **Bootstrap gist** — remote hosts curl this to clone/pull the repo and symlink the CLI

**Remote hosts run code from GitHub, not local checkout.** Push before integration tests.

## Architecture

- **Module pattern**: each `lib/*.sh` has a guard `_CLOUDIFY_X_LOADED`. Sourced by the router, not by each other.
- **Plugin API**: `pkg_*` functions in `lib/package-api.sh`. Signatures are stable — used by 65+ packages.
- **Shadow commands**: `lib/shadows/*.sh` override `sudo`, `apt-get`, `add-apt-repository`, `git` with wrappers for password injection, idempotency, auth. Recipes call bare commands — shadows handle the rest.
- **Credential management**: `~/.config/cloudify/credentials` (XDG, chmod 600). Generic loader — packages write arbitrary `export VAR='value'` lines.
- **Remote payload**: `declare -f` extracts template body as literal text, `envsubst` with explicit allow-list substitutes only listed vars. Single-quoted `$VAR` references resolve on the remote side.
- **Install guards**: stateful packages use `CLOUDIFY_FORCE`/`CLOUDIFY_CLEAR_DATA` convention. See "Install Guards" in README.md.
- **Runtime manager**: mise (preferred). Legacy gvm/nvm/pyenv replaced.
- **Container OS**: Ubuntu 24.04

## SDLC

TDD cycle. All tests run inside an Incus container (`cloudai:cloudify`), never on localhost.

**Prerequisites:** Incus, `ivps` CLI, running container `cloudai:cloudify`.

```bash
task setup-container   # One-time: install bats + libraries
task test-unit         # Push + unit tests
task test              # Push + all tests (unit + integration)
task lint              # Push + shellcheck
```

**Push before tests.** Integration tests SSH into the container, pull from GitHub, run there.

**Debugging:** Read `/tmp/cloudify/logs/<timestamp>.log`. Fix one issue, push, re-test.

**PRs:** `git push -u origin <branch>` then `gh pr create`.

**Recipe conventions:** see "Writing a Package Recipe" in README.md.

## Working Plan

`~/.claude/plans/radiant-noodling-giraffe.md`
