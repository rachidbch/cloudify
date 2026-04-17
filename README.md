# Cloudify

Bash-based host provisioning and package management for Ubuntu/Debian. Install and manage 60+ software packages on local and remote machines through a single CLI.

## What It Does

Cloudify installs development tools and system packages on Ubuntu/Debian machines. It works locally or remotely over SSH — a single command like `cloudify --on myserver install bat` SSHes into `myserver`, pulls the latest recipes from GitHub, and installs `bat` from its GitHub release.

**Key features:**

- **64 package recipes** — apt packages, GitHub releases, custom scripts
- **Remote execution** — install on any host reachable via SSH
- **Tag-based filtering** — group hosts and packages with `@tag` files
- **Host inventory** — define your fleet in `inventory/<host>/`
- **Plugin API** — stable `pkg_*` functions for writing new recipes

## Quick Start

```bash
# Clone and link
git clone https://github.com/rachidbch/cloudify.git ~/cloudify
sudo ln -sfn ~/cloudify/cloudify /usr/local/bin/cloudify

# Install essentials on this machine
cloudify install basics

# Install a specific tool
cloudify install bat

# List available packages
cloudify packages
```

## Usage

```
cloudify [action] [package]

Actions:
  install | i <pkg>           Install a package locally
  uninstall | u <pkg>         Uninstall a package locally
  --on <host> install <pkg>   Install a package on a remote host

Commands:
  help                        Print usage help
  init                        Initialize cloudify (once per session)
  credentials | c             Set credentials (local, remote, github, gitlab)
  packages | pkgs             List installable packages
  packages | pkgs default     List default packages
  hosts                       List remote hosts
  host <host>                 Print host status
  <host> shell                Open shell on remote host
  <host> exec <cmd>           Run command on remote host
  hostnames <host> [IP]       Add host IP to /etc/hosts
```

### Local install

```bash
cloudify install neovim       # apt-based install
cloudify install bat          # GitHub release install
cloudify install basics       # meta-package (curl, jq, tree, etc.)
```

### Remote install

```bash
# Install bat on a remote host (requires SSH access and credentials)
cloudify --on myserver install bat

# Install on multiple hosts
cloudify --on server1 server2 install git

# Install on hosts matching a tag
cloudify --on @web install nginx
```

Remote execution flow: cloudify SSHes into the target host, runs the bootstrap gist which clones/pulls `~/cloudify` from GitHub, then executes the package recipe. Credentials are injected into the payload via `envsubst` with an explicit allow-list.

## Package List

| Category | Packages |
|----------|----------|
| Essentials | basics, utils, git, ssh, ufw, gpg2 |
| Editors | neovim, vim, emacs-nox, spacemacs, leanmacs |
| Shell | bash-it, fzf, fasd, jump, tmux, tmux-compile, entr, xsel |
| Search & Browse | bat, fd, grep (silversearcher-ag via basics), pandoc |
| GitHub tools | gh, hub, lab, lazygit |
| Languages | python, go, ruby, php, mise, nvm, pyenv, miniconda3, sdkman |
| Databases | mysql, mariadb |
| Cloud & Infra | docker, digitalocean, scaleway, rclone, restic, hugo |
| Misc | croc, paping (tcping), yq, json, mosh, keepassxc, dotfiles, grv, snipster |

Run `cloudify packages` for the full list with tags.

## Configuration

### Credentials

Credentials are stored in environment variables. Set them interactively:

```bash
cloudify credentials
```

Or export them directly:

```bash
export CLOUDIFY_LOCAL_USER=myuser
export CLOUDIFY_LOCAL_PWD=mypassword
export CLOUDIFY_REMOTE_USER=root
export CLOUDIFY_REMOTE_PWD=serverpassword
export CLOUDIFY_GITHUBUSER=mygithub
export CLOUDIFY_GITHUBPWD=myghptoken
# ... see cloudify credentials for the full list
```

To skip credential prompts in automated contexts:

```bash
export CLOUDIFY_SKIPCREDENTIALS=true
```

### Host Inventory

Define hosts in `inventory/`:

```
inventory/
├── myserver/
│   ├── @web          # tag: web server
│   └── @production   # tag: production
├── staging/
│   └── @web
└── localhost/
    └── @local
```

Filter hosts by tag:

```bash
cloudify hosts @web           # list hosts tagged @web
cloudify --on @web install bat  # install on all @web hosts
```

### Package Tags

Tag packages with files in `pkg/<name>/`:

```
pkg/bat/@default     # bat is a default package
pkg/git/@basics      # git is a basic tool
pkg/mosh/@default
```

## Repository Structure

```
cloudify              CLI router (367 lines) — sources lib/*.sh modules
Taskfile.yml          Task runner definitions (task setup-container, task test, etc.)
lib/
  colors.sh           Terminal color setup
  credentials.sh      Credential management and prompting
  hosts.sh            Host inventory (list, filter by tags)
  os.sh               OS detection (distro, version, arch)
  package-api.sh      Public pkg_* plugin API used by package recipes
  packages.sh         Package discovery, recipe resolution, install/uninstall
  remote.sh           Remote execution via SSH with payload template
  shadow.sh           Git shadow repo management
  utils.sh            Utilities: msg, die, backup/restore, git URL parsing
pkg/
  <pkg>/init.sh       Package recipe (install script)
  <pkg>/@<tag>        Tag files for filtering
inventory/
  <host>/@<tag>       Host tag files for grouping
tests/
  unit/               Unit tests (mocked environment)
  integration/        Integration tests (real package installs via SSH)
  helpers/            Test setup/teardown helpers
```

## Developer Guide

### Prerequisites

- Incus installed and configured
- `ivps` CLI tool for container file push/exec
- `task` (Taskfile) — install via `mise use -g task`
- A running Ubuntu 24.04 container (default: `cloudai:cloudify`)
- `bats` 1.x on localhost for integration tests
- Tailscale for SSH-based integration tests

### TDD Workflow

All tests run inside the Incus container (unit tests) or via SSH against it (integration tests). Always use `task test-unit` or `task test`.

```bash
task setup-container    # Install bats + libraries in container (one-time)
task test-unit          # Sync files + run unit tests in container
task test-integration   # Run SSH-based integration tests from localhost
task test               # Run all tests (unit + integration)
task lint               # Run shellcheck in container
```

### Writing a Package Recipe

Each package lives in `pkg/<name>/init.sh`. Recipes use the `pkg_*` plugin API:

```bash
# Simple apt package
pkg_apt_install curl

# Install from GitHub release (auto-detects latest version + arch)
pkg_install_release bat "sharkdp/bat"

# Install another cloudify package as a dependency
pkg_depends git

# Backup a file before modifying it
pkg_backup /etc/someconfig

# Add a line to ~/.bashrc (within cloudify section marker)
pkg_in_startuprc 'export PATH="$HOME/.local/bin:$PATH"'
```

**Available API functions:**

| Function | Purpose |
|----------|---------|
| `pkg_apt_install <pkg>` | Install apt package (skips if present) |
| `pkg_apt_update [--force]` | Update apt cache |
| `pkg_apt_repository <repo>` | Add apt repository |
| `pkg_depends <pkg...>` | Install cloudify packages as dependencies |
| `pkg_install_release <name> <repo>` | Install latest GitHub release |
| `pkg_backup <path>` | Backup file/dir to temp location |
| `pkg_restore <path>` | Restore from backup |
| `pkg_in_startuprc <line>` | Add line to ~/.bashrc |

### Integration Tests

Integration tests exercise the full production path: `cloudify --on <host> install <pkg>` over SSH. Each test gets a clean container via snapshot restore.

```bash
task test-integration:bat       # Run single package test
task test-integration:json      # Run another
task test-integration           # Run all integration tests
```

Test file pattern (`tests/integration/package-<name>.bats`):

```bash
#!/usr/bin/env bats

TEST_HOST="cloudify"
TEST_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

@test "cloudify --on $TEST_HOST install mypackage succeeds" {
    run cloudify --on "$TEST_HOST" install mypackage
    [ "$status" -eq 0 ]
}

@test "mybin binary exists on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'command -v mybin'
    [ "$status" -eq 0 ]
}
```

### Contributing

1. Create a feature branch: `git checkout -b my-feature`
2. Write tests first, make them pass
3. Commit and push: `git push github my-feature`
4. Open a PR against `master` on GitHub

### Snapshot Management

Integration tests use an Incus snapshot (`itest-base`) for isolation:

```bash
task itest-base    # Create snapshot (clean Ubuntu 24.04 + bats + tailscale)
task itest-reset   # Restore clean snapshot
task itest-clean   # Delete snapshot
```
