# Cloudify — Optimization Decisions

## Conventions

- Each optimization is a markdown checkbox with status:
  - `[ ]` — agreed, not yet attempted
  - `[x]` — attempted, succeeded, kept in codebase
  - `[/]` — attempted, failed, discarded (reverted)
- Each entry has:
  - **Rational** — why this optimization is needed
  - **Approach** — how we will implement it
  - **Success criteria** — what proves it works
  - **Reason** — filled after attempt: why it succeeded or failed

---

## A: Remote output is invisible during package install

### A1: Remote side — tee to both log file and SSH channel

- [x] Replace `exec >> log 2>&1` with `exec > >(tee -a "$CLOUDIFY_LOG_FILE") 2>&1 </dev/null`
- **Rational:** Process substitution sends output to both the log file AND the SSH channel (back to local terminal). The original hang (2026-05-14) was likely caused by `cat -` blocking on stdin, not by process substitution. Now that `</dev/null` is in place, this should work.
- **Success criteria:** Remote install output visible on local terminal in real-time AND written to log file. Shadow sudo does not hang. No zombie processes after install completes.
- **Reason:** Unit tests verify tee process substitution + /dev/null stdin. Integration test will confirm real-time output.

### B1: Add `--clear-data` flag

- [x] Add `CLOUDIFY_CLEAR_DATA=true` env var, set by `--clear-data` CLI flag. Recipes check `${CLOUDIFY_CLEAR_DATA:-}` and delete their persistent data (e.g. `/opt/open-webui/data`) before reinstalling. `--clear-data` implies reinstall even if package is already present.
- **Rational:** Currently the only way to reset a package's state is `cloudify shell host 'rm -rf /path/to/data'`. A standard flag lets recipes handle their own cleanup. Global flag for now; future CLI grammar may support per-host/per-package scoping (see ROADMAP.md).
- **Success criteria:** `cloudify --on hermes --clear-data install hermes-openwebui` deletes open-webui DB, regenerates config, creates fresh admin account — all in one command.
- **Reason:** CLI flag parses, exports env var, passes through remote payload via envsubst. `--clear-data` also implies `CLOUDIFY_FORCE=true`.

### C1: Distinguish explicit dispatch from dependency pull

- [x] Set `CLOUDIFY_FORCE=true` for explicitly dispatched packages. Leave unset when `pkg_depends` sources a recipe. `--clear-data` sets `CLOUDIFY_CLEAR_DATA=true` on the explicit package only (not deps), and implies `CLOUDIFY_FORCE`.
- **Rational:** Dependencies overwrite existing config because `pkg_depends` re-sources recipes that unconditionally regenerate config files. Each recipe decides its own behavior: skip destructive writes when `CLOUDIFY_FORCE` is unset, nuke data when `CLOUDIFY_CLEAR_DATA` is set. Keeps the framework simple — no installed-package database, no state tracking.
- **Success criteria:** `cloudify --on hermes install hermes-openwebui` with env vars set → hermes-openwebui runs with `CLOUDIFY_FORCE`, its deps (open-webui, hermes) run without it. open-webui recipe detects existing docker-compose.yml and skips. No config overwrite.
- **Reason:** `pkg_depends` now runs recipes in a subshell with `unset CLOUDIFY_FORCE; unset CLOUDIFY_CLEAR_DATA`. Explicit dispatch sets `CLOUDIFY_FORCE=true`. Unit tests confirm deps don't see FORCE even when set in caller env.

### D1: Symlink latest log + match local/remote log filenames

- [x] After creating the log file on the remote, create/overwrite a symlink at `/tmp/cloudify/logs/latest.log`. Additionally, pass the local `CLOUDIFY_LOG_FILE` basename through the remote payload so the remote uses the same filename — this makes local and remote logs a matching pair by timestamp.
- **Rational:** Remote log files are timestamped (`20260515-211436.log`). To read them you must know the timestamp. A symlink solves "show me the latest". Matching filenames solves "which remote log corresponds to which local run".
- **Success criteria:** `cloudify shell hermes 'tail /tmp/cloudify/logs/latest.log'` always shows the most recent run. Local log at `/tmp/cloudify/logs/20260515-211436.log` has a matching remote log at the same path.
- **Reason:** `CLOUDIFY_LOG_BASENAME` passed through payload. Remote uses it if present, falls back to timestamp. `ln -sf` creates latest.log symlink. Unit tests confirm both.

### A2: Local side — line-buffer the sed pipeline

- [x] Add `--unbuffered` to sed calls in local SSH pipeline, or use `stdbuf -oL`
- **Rational:** Even if A1 works, the `| sed | sed | tee` pipeline in `cloudify_remote_sync` may buffer output. Line-buffering ensures each line appears promptly on the local terminal. Nice-to-have if A1 works, critical if A1 is discarded.
- **Success criteria:** Output appears line-by-line on local terminal without noticeable delay.
- **Reason:** `stdbuf -oL` wraps both sed calls. Unit test confirms stdbuf presence in function source.

### G1: Simplify hermes-openwebui integration test — remove redundant config fixture

- [x] Now that the hermes package auto-configures KeylessAI, the integration test (`tests/integration/package-hermes-openwebui.bats`) no longer needs to manually write `~/.hermes/.env` and `~/.hermes/config.yaml`. The hermes package handles it. Remove the "hermes configured with keyless Pollinations endpoint" test and let the auto-config do its job.
- **Rational:** Two systems writing the same config is redundant and fragile. If the auto-config changes, the test fixture must be updated separately. Trusting the hermes package's auto-config means fewer moving parts.
- **Success criteria:** Integration test still passes after removing the manual config fixture. Hermes gateway starts healthy, open-webui connects to it.
- **Reason:** Removed manual config fixture. Updated Docker reachability test to read auto-generated API key from hermes env instead of hardcoded value.

## Convention: CLOUDIFY_FORCE and CLOUDIFY_CLEAR_DATA in package recipes

### When to add the guard

Every package that creates **config files, data directories, docker containers, or systemd services** must have an install guard. Thin apt/binary-only installs (e.g. `bat`, `fd`, `jq`) are already idempotent and don't need it.

### Pattern

Place this block **after** `pkg_depends` and variable setup, **before** any install work:

```bash
# --- Install guard ---
if <already_installed> && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "<Package> already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Clear persistent data if requested ---
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    log_info "Clearing <package> data..."
    rm -rf <data_dir>
fi
```

### Rules

- **`<already_installed>`**: fastest reliable check. `command -v binary`, `-f config_file`, `-d dir`.
- **`CLOUDIFY_FORCE`**: set by framework for explicitly dispatched packages. Causes reinstall even if already present.
- **`CLOUDIFY_CLEAR_DATA`**: set by `--clear-data` flag. Implies FORCE. Wipes persistent data (databases, user content, generated config). Does **not** wipe the binary/installation itself.
- **What is "data"**: user-generated content, databases, uploaded files, session state. E.g. `/opt/open-webui/data`, `/var/lib/mysql`, `~/.hermes`.
- **What is NOT "data"**: config files generated by the recipe (`docker-compose.yml`, `.env`, `config.yaml`). These are regenerated on every install regardless.
- **Dependencies**: `pkg_depends` unsets both vars at depth>0. Deps never see FORCE or CLEAR_DATA. The guard is only relevant for the explicitly dispatched package.

### Already applied to

hermes, open-webui, hermes-openwebui

## E: Document FORCE/CLEAR_DATA convention as pkg dev guide

### E1: Add "Install Guards" subsection to README.md "Writing a Package Recipe"

- [ ] Add subsection defining the convention and code pattern for pkg authors
- **Rational:** Convention exists in OPTIMIZATIONS.md but pkg authors read README.md.
- **Convention to document (self-contained):**
  - **Software** = binaries, venvs, docker images, apt packages. Overwritten on every forced install.
  - **Data** = user config, databases, sessions, uploads, API keys. Preserved unless `--clear-data`.
  - **`CLOUDIFY_FORCE`**: set by framework for explicitly dispatched packages; unset for deps. Bypasses the skip guard to trigger reinstall.
  - **`CLOUDIFY_CLEAR_DATA`**: set by `--clear-data` flag (implies FORCE). Wipes persistent data only.
  - **Who needs it**: stateful packages (config, data dirs, containers). Thin apt/binary-only installs (bat, fd, jq) don't.
- **Code pattern to include verbatim:**
  ```bash
  pkg_depends <deps>

  # --- Install guard ---
  if <already_installed> && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
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
- **Success criteria:** A pkg author can implement install guards from this section alone, no other doc needed.

### E2: Audit all stateful packages for install guard compliance

- [ ] Audit all 73 packages; add install guards to every stateful package missing them
- **Rational:** hermes, open-webui, hermes-openwebui have guards. The other 70 packages may silently overwrite user data or skip reinstalls unpredictably.
- **Already compliant:** hermes, open-webui, hermes-openwebui
- **Likely exempt (thin installs):** bat, fd, fzf, croc, entr, gh, hugo, jq, yq, paping, xsel, lazygit, silversearcher-ag, hub, pcmd, jump, fasd, grv, megadown, snipster
- **Likely need guards (stateful):** docker, mariadb, mysql, rclone, restic, miniconda3, pyenv, sdkman, nvm, go, ruby, php, apache, openvpn, ufw, ssh, tmux, neovim, emacs-nox, spacemacs, leanmacs, vim, dotfiles, bash-it, hermes-signal, digitalocean, scaleway, mise, virtualenv, pip, pipx, play, lexicon, todo.txt, keepassxc, wezterm, gpg2, pandoc
- **Unclear — read to decide:** basics, git, gitless, required, rsync, json, lab, locate, tern, tmux-compile, vim, askpassstars, utils, python, dotfiles
- **Approach:** For each package in the "need guards" and "unclear" lists: read `init.sh`, classify as stateful or exempt, add guard if stateful and missing. Follow the code pattern from E1.
- **Success criteria:** Every stateful package has the install guard block. No thin packages get unnecessary guards. `task test-unit` passes after all changes.
