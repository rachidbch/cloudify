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
  credentials | c             Set all credentials interactively
  credentials remote          Set remote credentials only
  credentials github          Set GitHub credentials only
  credentials gitlab          Set GitLab credentials only
  credentials --check         Check credential status
  packages | pkgs             List installable packages
  packages | pkgs default     List default packages
  launch | run [remote:]<name> [image]  Launch container (default image: ubuntu/24.04/cloud)
  delete | del [remote:]<name>          Delete container
  hosts                       List remote hosts
  host <host>                 Print host status
  <host> shell                Open shell on remote host
  exec <host> <cmd>           Run command on remote host
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

Remote execution flow: cloudify SSHes into the target host, runs the bootstrap gist which clones/pulls `~/cloudify` from GitHub, then executes the package recipe. Credentials are injected into the payload via `envsubst` with an explicit allow-list. All remote SSH output is captured to a timestamped log file. If any host fails, the final status message reports the log path for debugging.

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

Credentials are stored in `~/.config/cloudify/credentials` (XDG-compliant, `chmod 600`). They are loaded automatically at startup — no need to source any file after reboot.

Set all credentials interactively:

```bash
cloudify credentials
```

Set only a specific section:

```bash
cloudify credentials remote    # CLOUDIFY_REMOTE_USER, CLOUDIFY_REMOTE_PWD
cloudify credentials github    # CLOUDIFY_GITHUBUSER, CLOUDIFY_GITHUBPWD
cloudify credentials gitlab    # CLOUDIFY_GITLABUSER, CLOUDIFY_GITLABPWD
```

Check which sections are configured:

```bash
cloudify credentials --check
```

Or export them directly (overrides file values):

```bash
export CLOUDIFY_REMOTE_USER=root
export CLOUDIFY_REMOTE_PWD=serverpassword
export CLOUDIFY_GITHUBUSER=mygithub
export CLOUDIFY_GITHUBPWD=myghptoken
```

To skip credential loading in automated contexts:

```bash
export CLOUDIFY_SKIPCREDENTIALS=true
```

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLOUDIFY_TMP` | `/tmp/cloudify` | Temp directory for logs, exit code files, and backups. Log files persist here after exit. |
| `CLOUDIFY_DIR` | `~/cloudify` | Path to the cloudify repository (used to find `pkg/` and `inventory/`). |
| `CLOUDIFY_CREDENTIALS_DIR` | `~/.config/cloudify` | Directory for the credentials file (XDG-compliant). |
| `CLOUDIFY_CREDENTIALS_FILE` | `~/.config/cloudify/credentials` | File where credentials are persisted (`chmod 600`). Loaded at startup. |
| `CLOUDIFY_SKIPCREDENTIALS` | `false` | Skip credential loading in automated contexts. |
| `CLOUDIFY_DISABLE_COLORS` | `false` | Disable colored output. |
| `CLOUDIFY_FORCE_UPDATE` | `false` | Force git pull on remote hosts regardless of update delay. |
| `CLOUDIFY_UPDATE_DELAY` | `30` | Minutes before auto-updating the remote repo. |
| `CLOUDIFY_LOG_LEVEL` | `INFO` | Log verbosity: `SILENT`, `CRITICAL`, `ERROR`, `WARN`, `INFO`, `DEBUG`. |

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
  containers.sh       Container operations via ivps (launch, delete, IP lookup)
  credentials.sh      Credential management: save, load, migrate, section-based prompting
  hosts.sh            Host inventory (list, filter by tags)
  os.sh               OS detection (distro, version, arch)
  package-api.sh      Public pkg_* plugin API used by package recipes
  packages.sh         Package discovery, recipe resolution, install/uninstall
  remote.sh           Remote execution via SSH with payload template
  shadow.sh           Shadow command loader (sources lib/shadows/*.sh)
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

Each package lives in `pkg/<name>/`. The only required file is `init.sh`.

#### Directory structure

```
pkg/hermes/
├── init.sh        # Required — the install recipe
└── @default       # Optional — tag file (empty file)
```

Tag files are empty files used for filtering. `@default` means the package is installed by `cloudify install default`. Create custom tags with `@<tag>` (e.g., `@web`, `@dev`).

#### Recipe conventions

Recipes are plain bash scripts. They run with `set -Eeuo pipefail` inherited from the main router. The `pkg_*` API functions are available automatically (no sourcing needed). The script runs inside the target environment (local or remote via SSH), so commands like `curl`, `apt-get`, and `bash` are available directly.

#### Minimal examples

**APT package:**
```bash
#!/usr/bin/env bash
# entr — run commands when files change
# doc: http://entrproject.org/
apt-get install -y entr
```

**GitHub release:**
```bash
#!/usr/bin/env bash
# bat — better cat
pkg_install_release bat "sharkdp/bat"
```

**Custom script with dependency:**
```bash
#!/usr/bin/env bash
# my-tool — needs git first
pkg_depends git
curl -fsSL https://example.com/install.sh | bash
```

#### Available API functions

| Function | Purpose |
|----------|---------|
| `pkg_apt_install <pkg...>` | Install apt packages (skips already-installed) |
| `pkg_apt_update [--force]` | Update apt cache |
| `pkg_apt_repository <repo>` | Add apt repository |
| `pkg_depends <pkg...>` | Install cloudify packages as dependencies (falls back to apt) |
| `pkg_install_release <name> <repo>` | Install latest GitHub release (auto-detects arch) |
| `pkg_backup <path>` | Backup file/dir to temp location (rotated, up to 5) |
| `pkg_restore <path>` | Restore from backup |
| `pkg_in_startuprc <line>` | Add line to ~/.bashrc (deduplicated) |
| `PKG_DEBUG <msg>` | Print debug message when `DEBUG=true` |

#### `pkg_depends` behavior

For each argument, `pkg_depends` checks if a cloudify recipe exists (`pkg/<name>/init.sh`). If yes, it runs that recipe. If not, it falls back to `pkg_apt_install`. This means `pkg_depends git jq bat` works regardless of whether those are cloudify packages or plain apt packages.

### Shadow Command System

Package recipes call `sudo`, `apt-get`, `add-apt-repository`, and `git` as plain commands — no password handling, no idempotency checks, no authentication logic. These commands are **shadowed** by wrapper functions that transparently inject the necessary behavior. This is what makes a one-line recipe like `apt-get install -y entr` work both locally and on a remote host over SSH.

**How shadowing works:** `lib/shadow.sh` sources all scripts in `lib/shadows/*.sh` at startup. Each script defines a function with the same name as the command it replaces (e.g., `function sudo() { ... }`). Inside the function, `command sudo` calls the real binary. Recipes never import or configure anything — the shadows are active by the time `init.sh` runs.

#### Password flow (local to remote sudo)

```
Credentials stored in               Password injected at point of use
~/.config/cloudify/credentials      (shadow sudo() function)
        │                                    │
        ▼                                    ▼
cloudify_credentials_load       cloudify_get_password reads CLOUDIFY_HOSTPWD
sets CLOUDIFY_REMOTE_PWD                 │
        │                                ▼
        ▼                       command sudo -kS -p "" bash -c "$cmd" <<< "$password"
envsubst injects                        │
CLOUDIFY_REMOTE_PWD              -k forces re-auth
into CLOUDIFY_HOSTPWD             -S reads password from stdin
on remote host                    herestring supplies password
```

Credentials are loaded from `~/.config/cloudify/credentials` at startup. Environment variables override file values. For remote execution, `lib/remote.sh` uses `envsubst` with an explicit allow-list to inject `CLOUDIFY_REMOTE_PWD` as `CLOUDIFY_HOSTPWD` in the SSH payload. Passwords are redacted to `***********` in debug output.

#### Shadow `sudo`

The shadow `sudo()` (`lib/shadows/sudo.sh`) handles the core challenge: sudo needs the password on stdin (via `-S`), but stdin may already be in use by a pipe (e.g., `echo 'data' | sudo tee file`). The function:

1. Calls `cloudify_get_password` to read `CLOUDIFY_HOSTPWD`
2. Detects whether stdin is a pipe or a terminal
3. If piped: captures stdin into a variable, then rearranges the call as `echo '<piped_data>' | <command>` passed as a string argument to `bash -c` — this frees stdin for the password herestring
4. Executes `command sudo -kS -p "" bash -c "$sudocmd" <<< "$password"` — the herestring supplies the password via stdin while `-S` tells sudo to read it from stdin

#### Shadow `apt-get`

The shadow `apt-get()` (`lib/shadows/apt-get.sh`) adds two layers on top of the shadow `sudo`:

- **Idempotency**: `apt-get install` checks `dpkg -l` and skips already-installed packages
- **Auto-update**: if the apt cache is older than 60 minutes, it runs `apt-get update` automatically before installing

The `apt` command is also shadowed as a simple alias to the `apt-get` shadow.

#### Shadow `add-apt-repository`

The shadow `add-apt-repository()` (`lib/shadows/add-apt-repository.sh`) adds:

- **Idempotency**: checks `/etc/apt/sources.list.d/*` for the repository before adding
- **Auto-update**: runs `apt-get update --force` after adding a new repository

#### Shadow `git`

The shadow `git()` (`lib/shadows/git.sh`) handles two concerns:

- **Authentication**: for `git clone` and other operations against GitHub/GitLab, it sets up `GIT_ASKPASS` with a script that echoes the appropriate token (`CLOUDIFY_GITHUBPWD` or `CLOUDIFY_GITLABPWD`). It also configures `url.insteadOf` rules to force HTTPS connections.
- **Clone-to-pull conversion**: if `git clone` targets a directory that already exists and contains a repo pointing to the same remote, it silently converts the operation to `git pull` instead of failing.

### Logging & Error Reporting

When cloudify runs package installations (locally or remotely), it captures all output to a timestamped log file and reports failures clearly.

**What gets logged:** Every `cloudify_remote_sync` call (both localhost and SSH branches) tees its output to `$CLOUDIFY_TMP/logs/<timestamp>.log`. This includes the full SSH stdout/stderr from remote hosts, prefixed with the hostname.

**Failure propagation:** Backgrounded installs run in parallel across hosts. Each one writes its exit code to `$CLOUDIFY_TMP/<host>.exit`. The main router waits for all background PIDs individually — if any fails, the final message shows:

```
Setup completed with errors. Log: /tmp/cloudify/logs/20260421-143052.log
```

**Log persistence:** The `cleanup()` function preserves `$CLOUDIFY_TMP/logs/` on exit, so log files survive for post-mortem debugging. All other temp files are removed. When `DEBUG=true`, everything is preserved.

**Exit code files:** `$CLOUDIFY_TMP/<host>.exit` contains the numeric exit code from each host's SSH session. These are cleaned up with the rest of the temp directory (but logs persist).

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

### Testing Docker & AI Packages

Packages that run Docker containers (e.g. `open-webui`) or connect to AI services (e.g. `hermes-openwebui`) need special handling in integration tests because they have heavier dependencies (Docker, a running LLM backend).

#### Docker packages

Docker is declared as a dependency via `pkg_depends docker` in the recipe. The integration test doesn't need to pre-install Docker — `cloudify install` pulls it in automatically. Tests verify the systemd service, container status, and health endpoint.

#### AI packages requiring an LLM backend

Testing `hermes-openwebui` requires a running Hermes gateway with an active LLM provider. Using a paid API (OpenRouter, Anthropic, etc.) is risky because:
- API keys are tied to accounts with billing enabled
- Keys can leak in test output or CI logs
- Free tiers on major providers still require a credit card on file

The solution is **KeylessAI** — a free, keyless, no-account, no-credit-card OpenAI-compatible endpoint with auto-failover across Pollinations and ApiAirforce:

```
Base URL: https://keylessai.thryx.workers.dev/v1
Model:    openai-fast
API key:  not-needed (any string works)
```

Hermes supports a `custom` provider that can point at any OpenAI-compatible URL. The test fixture configures it like this:

```bash
# Test fixture: write to ~/.hermes/.env on the container
API_SERVER_ENABLED=true
API_SERVER_PORT=8642
API_SERVER_KEY=test-integration-key
```

```bash
# Test fixture: write to ~/.hermes/config.yaml on the container
model: openai-fast
provider: custom
base_url: https://keylessai.thryx.workers.dev/v1
```

No secrets, no environment variables, no risk. If the URL leaks, it's already public. The Hermes gateway talks to KeylessAI for LLM inference (which auto-fails over across providers), and Open WebUI connects to the Hermes API server at `http://127.0.0.1:8642/v1`.

**Pattern for AI integration tests:**

1. Install the AI package (`hermes`) — `cloudify --on cloudify install hermes`
2. Write config files to `~/.hermes/` with the KeylessAI endpoint
3. Start the gateway in the background, wait for `/health`
4. Install the UI package (`open-webui`)
5. Install the glue package (`hermes-openwebui`)
6. Assert the wiring is correct (backend URL in docker-compose.yml, API key set, services healthy)

**Caveat:** KeylessAI is a free community service with no SLA. It wraps Pollinations and ApiAirforce with auto-failover, so it's more resilient than a single provider — but if all upstreams are down, AI-related tests will fail. For CI reliability, consider making these tests skippable with a guard check on the endpoint.

### Contributing

1. Create a feature branch: `git checkout -b my-feature`
2. Write tests first, make them pass
3. Commit and push: `git push github my-feature`
4. Open a PR against `master` on GitHub

### Security Considerations

**Host key verification is disabled.** Both cloudify and ivps use `StrictHostKeyChecking=no` on all SSH connections (including rsync-over-SSH). This is necessary because:

- Containers are created and destroyed frequently — their host keys change every time
- Remote execution is non-interactive — there is no TTY to prompt for host key acceptance

**The risk:** disabling host key checking means SSH will not detect man-in-the-middle attacks. An attacker who can intercept network traffic between your machine and a target host could impersonate that host.

**Mitigations:**

- On trusted networks (local Incus containers, Tailscale mesh), the MITM surface is minimal
- For production hosts, pre-populate `~/.ssh/known_hosts` manually and remove `StrictHostKeyChecking=no` from your SSH config
- Tailscale SSH provides its own host verification independent of SSH host keys — this is the recommended approach for remote hosts

**Future improvement:** cloudify could pre-populate `known_hosts` from the inventory or parse SSH banners to prompt the user on first connection (as noted in `lib/remote.sh`).

### Snapshot Management

Integration tests use an Incus snapshot (`itest-base`) for isolation:

```bash
task itest-base    # Create snapshot (clean Ubuntu 24.04 + bats + tailscale)
task itest-reset   # Restore clean snapshot
task itest-clean   # Delete snapshot
```
