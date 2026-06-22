# Cloudify

## Constitution (project-specific; global rules in ~/AGENTS.md)
- **Timeouts.** Estimate task time, set 3×. Never fail a command by being too conservative.
- **Tool priority.** cloudify > ivps > incus; incus only with explicit consent.
- **Verify stuck before killing.** A slow mutating op isn't a hang - confirm no progress (D-state, zero I/O) first. Mid-op kills leave dirty state that breaks the next run.
- **Docs before code, logs before hypotheses.** Read README/AGENTS + logs before diagnosing; never assert an unconfirmed root cause.

## Conventions

- **`--on <host>`** comes BEFORE the action verb: `cloudify --on host install pkg`

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
- **Verification**: optional `pkg/<name>/verify.sh` defines `pkg_verify()`, sourced in a clean subshell by `_cloudify_run_verify` after every package (deep verify, incl. deps). `--no-verify` skips, `--verify`/`cloudify verify` is verify-only. See "Verification" in README.md.
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


## Working Plan

