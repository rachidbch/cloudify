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

- [ ] Replace `exec >> log 2>&1` with `exec > >(tee -a "$CLOUDIFY_LOG_FILE") 2>&1 </dev/null`
- **Rational:** Process substitution sends output to both the log file AND the SSH channel (back to local terminal). The original hang (2026-05-14) was likely caused by `cat -` blocking on stdin, not by process substitution. Now that `</dev/null` is in place, this should work.
- **Success criteria:** Remote install output visible on local terminal in real-time AND written to log file. Shadow sudo does not hang. No zombie processes after install completes.
- **Reason:**

### B1: Add `--clear-data` flag

- [ ] Add `CLOUDIFY_CLEAR_DATA=true` env var, set by `--clear-data` CLI flag. Recipes check `${CLOUDIFY_CLEAR_DATA:-}` and delete their persistent data (e.g. `/opt/open-webui/data`) before reinstalling. `--clear-data` implies reinstall even if package is already present.
- **Rational:** Currently the only way to reset a package's state is `cloudify shell host 'rm -rf /path/to/data'`. A standard flag lets recipes handle their own cleanup. Global flag for now; future CLI grammar may support per-host/per-package scoping (see ROADMAP.md).
- **Success criteria:** `cloudify --on hermes --clear-data install hermes-openwebui` deletes open-webui DB, regenerates config, creates fresh admin account — all in one command.
- **Reason:**

### C1: Distinguish explicit dispatch from dependency pull

- [ ] Set `CLOUDIFY_FORCE=true` for explicitly dispatched packages. Leave unset when `pkg_depends` sources a recipe. `--clear-data` sets `CLOUDIFY_CLEAR_DATA=true` on the explicit package only (not deps), and implies `CLOUDIFY_FORCE`.
- **Rational:** Dependencies overwrite existing config because `pkg_depends` re-sources recipes that unconditionally regenerate config files. Each recipe decides its own behavior: skip destructive writes when `CLOUDIFY_FORCE` is unset, nuke data when `CLOUDIFY_CLEAR_DATA` is set. Keeps the framework simple — no installed-package database, no state tracking.
- **Success criteria:** `cloudify --on hermes install hermes-openwebui` with env vars set → hermes-openwebui runs with `CLOUDIFY_FORCE`, its deps (open-webui, hermes) run without it. open-webui recipe detects existing docker-compose.yml and skips. No config overwrite.
- **Reason:**

### D1: Symlink latest log + match local/remote log filenames

- [ ] After creating the log file on the remote, create/overwrite a symlink at `/tmp/cloudify/logs/latest.log`. Additionally, pass the local `CLOUDIFY_LOG_FILE` basename through the remote payload so the remote uses the same filename — this makes local and remote logs a matching pair by timestamp.
- **Rational:** Remote log files are timestamped (`20260515-211436.log`). To read them you must know the timestamp. A symlink solves "show me the latest". Matching filenames solves "which remote log corresponds to which local run".
- **Success criteria:** `cloudify shell hermes 'tail /tmp/cloudify/logs/latest.log'` always shows the most recent run. Local log at `/tmp/cloudify/logs/20260515-211436.log` has a matching remote log at the same path.
- **Reason:**

### A2: Local side — line-buffer the sed pipeline

- [ ] Add `--unbuffered` to sed calls in local SSH pipeline, or use `stdbuf -oL`
- **Rational:** Even if A1 works, the `| sed | sed | tee` pipeline in `cloudify_remote_sync` may buffer output. Line-buffering ensures each line appears promptly on the local terminal. Nice-to-have if A1 works, critical if A1 is discarded.
- **Success criteria:** Output appears line-by-line on local terminal without noticeable delay.
- **Reason:**

### G1: Simplify hermes-openwebui integration test — remove redundant config fixture

- [ ] Now that the hermes package auto-configures KeylessAI, the integration test (`tests/integration/package-hermes-openwebui.bats`) no longer needs to manually write `~/.hermes/.env` and `~/.hermes/config.yaml`. The hermes package handles it. Remove the "hermes configured with keyless Pollinations endpoint" test and let the auto-config do its job.
- **Rational:** Two systems writing the same config is redundant and fragile. If the auto-config changes, the test fixture must be updated separately. Trusting the hermes package's auto-config means fewer moving parts.
- **Success criteria:** Integration test still passes after removing the manual config fixture. Hermes gateway starts healthy, open-webui connects to it.
- **Reason:**
