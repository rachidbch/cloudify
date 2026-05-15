# Cloudify

## CRITICAL: Token Efficiency

When editing .md files (including CLAUDE.md, README.md, etc.), ALWAYS BE TOKEN EFFICIENT.

                        --- TOKEN EFFICIENT = MIN TOKEN WITH MAX SIGNAL ---

## CRITICAL: CLI Argument Order

`--on <host>` is a **flag** that must come BEFORE the action verb: `cloudify --on host install pkg` (NOT `cloudify install pkg --on host`).

## CRITICAL: Append-only Project History

- ALWAYS log you actions/outcomes in the append-only `HISTORY.md` at repo root.
- NEVER edit or delete previous entries.

Format: `## YYYY-MM-DD — <short description>` + bullets (changes, files, decisions, next steps).

## Big Picture

Cloudify is two things:

### 1. A GitHub repository

**https://github.com/rachidbch/cloudify**

The repo contains both a library of package recipes and the code that makes installation work locally and remotely via SSH. It is a bash-based host provisioning and package management tool for Ubuntu/Debian systems.

**Repository structure:**

```
cloudify              # CLI router (~300 lines) — sources lib/*.sh modules
lib/                  # Extracted library modules
  colors.sh           # Terminal color setup
  containers.sh       # Container operations via ivps (launch, delete, IP lookup)
  credentials.sh      # Credential management: save, load, migrate, section-based prompting
  hosts.sh            # Host inventory (list, filter by tags)
  os.sh               # OS detection (distro, version, arch)
  package-api.sh      # Public pkg_* plugin API used by 65+ package scripts
  packages.sh         # Package discovery, recipe resolution, install/uninstall
  remote.sh           # Remote execution via SSH with payload template
  shadow.sh           # Shadow command loader (sources lib/shadows/*.sh)
  utils.sh            # Utilities: msg, die, backup/restore, git URL parsing
pkg/                  # Package library — one directory per package
  <pkg>/init.sh       # Package recipe (install script)
  <pkg>/#<tag>        # Tag files for filtering
  <pkg>/@<tag>        # Virtual tag files
inventory/            # Host inventory — one directory per host
  <host>/@<tag>       # Tag files for host grouping
tests/                # Bats test suite
  unit/               # Unit tests (mocked environment)
  integration/        # Integration tests (real package installs)
  helpers/            # Test setup/teardown helpers
```

### 2. A bootstrap URL

**https://gist.githubusercontent.com/rachidbch/2e10095b0042e784c557a15e2c804807/raw/3741c58d083f1463f6580e792f75ec227744a304/cloudify.sh**

This is a small gist script that runs on remote hosts. It clones/pulls the GitHub repo into `~/cloudify` and symlinks `~/cloudify/cloudify` to `/usr/local/bin/cloudify`. It uses `CLOUDIFY_HOSTPWD` for non-interactive sudo when available, or falls back to interactive sudo.

The `CLOUDIFY_BOOTSTRAP_URL` constant in the cloudify script points to this gist. During remote execution (`cloudify install <pkg> --on <host>`), the payload template curls this URL to ensure the remote host has the latest code before running the cloudify command.

## Remote Execution Flow

When `cloudify install bat --on myhost` runs:

1. `cloudify_remote_sync("myhost", "install bat")` builds a payload from the template function
2. `declare -f` extracts the template body (which uses `$VAR` references in single quotes), then `envsubst` with an explicit allow-list substitutes only the listed variables
3. SSH sends the payload: env vars + `bash -c "$(curl -sL <gist_url>)"` + `cloudify install bat`
4. On the remote host: the gist clones/pulls `~/cloudify` from **GitHub** (not local), symlinks `/usr/local/bin/cloudify`, then `cloudify install bat` runs the package recipe

**Remote hosts run code from GitHub, not your local checkout.** Push before running integration tests. Tags (`@default`, `@web`) are files in `pkg/<name>/` — they travel with the repo and resolve identically on local and remote hosts.

## Contributing: Package Enriching & Updating

**For package recipe conventions, API reference, and examples, see the "Writing a Package Recipe" section in `README.md`.** This doc is the single source of truth for how to create new packages.

Cloudify is open to community contributions via GitHub PRs. The development workflow is TDD-based:

### 1. Develop locally with TDD

All code changes follow a strict test-driven cycle. Tests run exclusively inside an Incus container (never on the local machine) to ensure a clean Ubuntu 24.04 environment.

**Critical: remote hosts run code from GitHub.** Integration tests SSH into the container, clone/pull from GitHub, and run the code there. `git push` before integration tests or your changes won't take effect.

**Prerequisites:**
- Incus installed and configured
- `ivps` CLI tool available (`/home/rbc/PROJECTS/PROD/ivps/`)
- A running container: `cloudai:cloudify`

**TDD loop using Taskfile:**

```bash
task setup-container   # Install bats + libraries in container (one-time)
task test-unit         # Push files + run unit tests in container
task test              # Push files + run all tests (unit + integration)
task lint              # Push files + run shellcheck in container
```

Always use `task test-unit` or `task test`. The `sync` task pushes local files into `/root/cloudify/` in the container before executing tests.

**Debugging integration test failures — fix one thing at a time:**

1. Read the logs: `/tmp/cloudify/logs/<timestamp>.log` on localhost (full SSH output), `/tmp/cloudify/logs/` on container (remote-side)
2. Identify the first failure — execution is sequential: `cloudify init` → `@default` packages → your package. If `init` dies, your package never runs
3. Fix one issue, push, re-test. Don't stack fixes
4. Check if the failure is yours or a pre-existing `@default` package — `@default` packages install before yours. Fix the broken package (or remove its `@default` tag), push, then re-test yours

**Test structure:**
- `tests/unit/` — unit tests using mock `$CLOUDIFY_DIR` with fake `pkg/` and `inventory/` dirs (no real packages installed)
- `tests/integration/` — integration tests that install real packages in the container
- `tests/helpers/common.bash` — unit test setup: creates temp dirs, sets env vars, sources modules
- `tests/helpers/integration.bash` — integration test setup: points to real repo, sources all lib modules

### 2. Open a PR on GitHub

```bash
git checkout -b my-feature
git add <changed files>
git commit -m "Description of change"
git push -u origin my-feature
gh pr create --title "Description" --body "Summary of changes"
```

Push with `git push` — `origin` is the GitHub repo (`https://github.com/rachidbch/cloudify.git`).

## Architecture Notes

- **Testing framework**: bats-core with bats-assert, bats-support, bats-file
- **Module pattern**: each `lib/*.sh` has a guard `[[ -n "$_CLOUDIFY_X_LOADED" ]] && return 0`
- **Plugin API stability**: `pkg_*` function signatures must not change — they are used by 65+ package scripts
- **Remote payload template**: `lib/remote.sh` uses single-quoted `$VAR` references in the template function. `declare -f` extracts the body as literal text, then `envsubst` with an explicit allow-list substitutes only the listed variables. This avoids expanding `$HOME` or `$(...)` that must resolve on the remote side.
- **Runtime manager**: mise (`pkg/mise`) is the preferred runtime manager for Go, Node.js, and Python. Legacy packages (gvm, nvm, pyenv) have been replaced with mise-based recipes.
- **Shadow command system**: `lib/shadow.sh` sources `lib/shadows/*.sh` which override `sudo`, `apt-get`, `add-apt-repository`, and `git` with wrapper functions. This is the mechanism that makes remote sudo work without interactive prompts. The chain is: `CLOUDIFY_CREDENTIALS_FILE` → `cloudify_credentials_load()` → `CLOUDIFY_HOSTPWD` → `cloudify_get_password` → herestring to `command sudo -kS`. Package recipes call bare `sudo`/`apt-get`/`git` — the shadows handle password injection, idempotency, and authentication transparently. See "Shadow Command System" in README.md for full documentation.
- **Credential management**: Credentials are stored in `~/.config/cloudify/credentials` (XDG-compliant, `chmod 600`). `cloudify_credentials_load()` is called at startup in `cloudify_init_paths()` and sources the file without overwriting existing env vars — it loads any `export VAR='value'` line generically, so packages can write arbitrary vars to the file. `cloudify_credentials_save [section]` persists a specific infrastructure section (remote, github, gitlab). `cloudify_credentials_migrate()` handles one-time migration from legacy locations (`~/cloudify/.credentials`, `/dev/shm/cloudify_credentials`). The `cloudify credentials` subcommand supports section-based prompting: `cloudify credentials remote` prompts only for `CLOUDIFY_REMOTE_USER`/`CLOUDIFY_REMOTE_PWD`. Package-specific credentials (e.g., restic/rclone) are NOT hardcoded — packages manage their own env vars, which the generic loader picks up. `launch`/`delete` commands require no credentials — they delegate to ivps.
- **Logging & error propagation**: `cloudify_init_log()` in `lib/utils.sh` creates a timestamped log file under `$CLOUDIFY_TMP/logs/`. `cloudify_remote_sync()` tees all SSH/local output to this file. Each backgrounded host writes its exit code to `$CLOUDIFY_TMP/<host>.exit`. The main router tracks PIDs in `_CLOUDIFY_BG_PIDS` and waits for each individually, reporting failures with the log path. `cleanup()` preserves the `logs/` directory so log files survive after exit. See "Logging & Error Reporting" in README.md for full documentation.
- **Container OS**: Ubuntu 24.04 (matches production target)

## Working Plan

The full refactoring plan with phases, module extraction order, and verification steps is at:

**`~/.claude/plans/radiant-noodling-giraffe.md`**

Consult this plan for extraction order, module boundaries, test specifications, and commit milestones.
