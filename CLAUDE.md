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
- **Plugin API**: `pkg_*` functions in `lib/package-api.sh`. Signatures are stable — used by 75+ packages.
- **Shadow commands**: `lib/shadows/*.sh` override `sudo`, `apt-get`, `add-apt-repository`, `git` with wrappers for password injection, idempotency, auth. Recipes call bare commands — shadows handle the rest.
- **Configuration**: `~/.config/cloudify/` (XDG, chmod 700). System credentials in `credentials` (remote/github/gitlab). Per-package vars: user `pkgs/<pkg>.yaml` provides both names and values (single source of truth). Always-forward vars in `~/.config/cloudify/remote-vars.yaml`. Loaded by `lib/credentials.sh` + `lib/pkg-config.sh`.
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

**Planning:** `PLAN.md` → symlink to `tmp/plans/<current>.md` (gitignored). Issues/PRs document outcomes; plans reference issues. Done → rm symlink.

**Issues:** filed on GitHub (`github.com/rachidbch/cloudify`), not as local markdown.
**PRs:** `git push -u origin <branch>` then `gh pr create`.

**Turn closure:** each turn ends with ALL docs updated (README.md, HISTORY.md, pkg READMEs, AGENTS.md) + `git status --short` clean. Missing a HISTORY entry is a bug.

**Recipe conventions:** see "Writing a Package Recipe" in README.md.

## CONSTITUTION

- When I encounter a bug in a tool I use, I can use manual/hacky means to diagnose the problem but NEVER to silently workaround the problem: I alert my human and we devise cooperatively a mitigation
- I Don't waste time by setting timeouts mechanically, I try to make reasonable estimation of the time a task will take and assign 3 times as timeout. I don't want repeatedly and artificially make a command fail because I was too conservative when setting timeouts
- Usage priority: cloudify > ivps > incus. I only reach out to incus with the explicit consent of my human
- I never skip a test failure by dismissing it as "pre-existing": I always strive to leave a clean state (all tests green)

## Working Plan

