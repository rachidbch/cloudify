---
name: cloudify
description: Provision software on Ubuntu/Debian hosts with the `cloudify` CLI, and author new package recipes. Use when the user mentions cloudify, wants to install/uninstall/verify on a host or fleet, manage an inventory, or create a new package (`pkg/<name>/init.sh`).
---

# Cloudify

Bash CLI for installing packages on Ubuntu/Debian — locally or over SSH.

Discovery: `cloudify packages` lists all installable packages. Each `pkg/<name>/init.sh` header comment describes what it does (e.g. `# bat is better cat`). `cloudify packages show <pkg>` prints the full recipe.

## The one rule

`--on <host>` comes BEFORE `install`/`uninstall` — never after:

```bash
cloudify --on srv install bat      # correct
cloudify install bat --on srv      # runs locally, ignores --on
```

## Commands

```bash
cloudify install|inst|i <pkg...>          # local install (auto-installs @default first)
cloudify --on <host|@tag> install <pkg>   # remote install, parallel across hosts
cloudify uninstall|u <pkg>                # STUB — not yet implemented
cloudify verify <pkg>                     # verify-only (local)
cloudify --verify install <pkg>           # verify-only alias
cloudify --no-verify install <pkg>        # skip verify
cloudify --no-defaults install <pkg>      # install only basics (not full @default)
cloudify --clear-data install <pkg>       # wipe persistent data, force reinstall

cloudify packages [@tag|default|show <pkg>]   # list by tag, or print recipe
cloudify hosts [@tag]                          # inventory, filtered by tag
cloudify host <host>                           # single-host status
cloudify info <host> [ipv4|ipv6]              # container IP
cloudify <host> shell                          # interactive SSH, or `-i`
cloudify exec <host> '<cmd>'                   # non-interactive SSH
cloudify launch [remote:]<name> [image]        # create container (default: ubuntu/24.04/cloud)
cloudify delete [remote:]<name>                # delete container
cloudify credentials [remote|github|gitlab]    # set credentials
cloudify credentials --check                   # credential status
cloudify hostnames <host> [IP]                 # add to /etc/hosts
cloudify init                                  # first-run: PATH, tools, credentials
```

`cloudify help` lists everything.

## Key facts

- **Remote hosts pull from GitHub, not your checkout** → `git push` before testing remote changes.
- `@default` packages auto-install on every host before any requested package.
- Install verifies by default (opt-in `verify.sh` per package). Deep verify: deps verified too.
- On failure, read the log: `/tmp/cloudify/logs/<timestamp>.log`.
- `CLOUDIFY_FORCE` = set for explicit installs; unset for `pkg_depends` pulls.
- `CLOUDIFY_CLEAR_DATA` = `--clear-data` flag, implies FORCE, wipes persistent data.
- **`uninstall` is a stub** — raises `die "not ready"`.

## Authoring a package

File layout:
```
pkg/<name>/
├── init.sh        # required — the install recipe
├── verify.sh      # optional — defines pkg_verify() { ...; return 0; }
├── @default       # optional — empty tag file (installed by cloudify install default)
└── #linux         # optional — platform filter (only installs on matching OS)
```

Recipe API (`lib/package-api.sh`):
```bash
pkg_apt_install <pkg...>            # apt-get install (idempotent via shadow)
pkg_apt_update [--force]            # apt-get update
pkg_apt_repository <ppa>            # add-apt-repository (idempotent)
pkg_install_release <name> <repo>   # GitHub release download (auto arch)
pkg_depends <pkg...>                # cloudify pkg if exists, else apt fallback
pkg_backup <path>                   # backup file/dir (rotated, up to 5)
pkg_restore <path>                  # restore from backup
pkg_in_startuprc <line>             # deduped append to ~/.bashrc
PKG_DEBUG <msg>                     # debug output (when DEBUG=true)
```

Install guard pattern for stateful packages:
```bash
pkg_depends <deps>
if <already_installed_check> && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "Already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    rm -rf <data_dir>
fi
# ... install ...
```

Verify runs in clean subshell (env vars + disk only, not recipe locals). Use `PKG_VERIFY_TIMEOUT` from `pkgs/<pkg>.yaml` or env. Details: README.md "Verification" section.

Full authoring docs: `README.md` sections "Writing a Package Recipe" and "Verification".

## Credentials & secrets

- System secrets: `~/.config/cloudify/credentials` (0600), set via `cloudify credentials <section>` (remote, local, github, gitlab).
- Forwarding: only vars on lib/remote.sh's envsubst allow-list reach the host — a var is inert otherwise.
- git auth on hosts: the git shadow uses GIT_ASKPASS + url.insteadOf and needs a TOKEN; GitHub rejects passwords (since 2021). Use `CLOUDIFY_GITHUB_READONLY_TOKEN` (fine-grained PAT, Contents: read-only) for clones.
- Package-level secrets: `pkg/<name>/.remote-vars` — NAMES in repo, values from caller env at install (ADR-007).
