# Cloudify Roadmap

## Error aggregation in `cloudify_install_package`

`cloudify_install_package()` in `lib/packages.sh` calls `pkg_depends "$pkg"` in a loop, one package at a time. With `set -e` active, the first failure aborts the entire function — remaining packages are never attempted, and no error report is printed.

This is inconsistent with the design principle that **error aggregation belongs at the orchestration level**. `pkg_depends` already collects errors within a single call, but `cloudify_install_package` doesn't benefit from it when installing multiple packages (e.g. `cloudify install foo bar baz`).

**Proposed fix**: Apply the same error-collection pattern — continue through failures, collect failed package names, report comprehensive list at end.

## Parity between local and remote logging

Remote execution (`cloudify install foo --on myhost`) captures all stdout/stderr in `$CLOUDIFY_LOG_FILE` via `tee -a`. Local execution (`cloudify install foo`) only logs `msg`/`log_*` calls — bare `echo`, command output, and subcommand errors from package recipes are lost.

**Proposed fix**: Tee local package execution to the log file the same way `cloudify_remote_sync` does for localhost (remote.sh:74). This ensures local installs produce the same complete log as remote ones.

## Audit package recipes for proper logging

Many packages use bare `echo` instead of `msg`/`log_*` functions, so their output is not captured in `$CLOUDIFY_LOG_FILE` and has inconsistent formatting. Example: `pkg/hermes/init.sh` uses no `msg` or `log_*` calls at all.

**Proposed fix**: Review all package recipes (`pkg/*/init.sh`) and convert bare `echo`/`printf` to the appropriate `msg`, `log_info`, `log_warn`, or `log_error` calls. This gives consistent formatting, proper log capture, and better UX when debugging failed installs.

## Stream remote logs live

Remote execution pipes SSH output through `sed | tail | tee`, which buffers everything — logs appear only after the SSH session completes. During long installs (docker pulls, locale generation), the user sees `Setup of machines in progress...` with no feedback, and the log file on localhost is empty until the remote finishes.

**Proposed fix**: Write logs live on the remote host (e.g. `tee` to a remote log file inside the payload template) so they can be inspected during install with `ssh myhost tail -f /tmp/cloudify/logs/...`. Also surface the log path to the user in the "Setup of machines in progress..." message so they know where to look.

## Per-package remote env var declarations

### Problem

When `cloudify --on hermes install open-webui` runs, a fresh bash session starts on the remote host. It knows nothing about local env vars. The bridge is the payload template in `lib/remote.sh`, which uses `envsubst` with a hardcoded allow-list to substitute local values into the remote payload.

Currently, every env var that must reach the remote host requires **two manual edits** in `lib/remote.sh`:
1. Add `export MY_VAR='$MY_VAR'` to `cloudify_remote_payload_template()`
2. Add `$MY_VAR` to the `envsubst` allow-list string

If either is forgotten, the var arrives empty on the remote — no error, no warning, just silent default behavior.

This means the cloudify core (`lib/remote.sh`) must be modified every time a package needs a new env var remotely. The open-webui package (`WEBUI_ADMIN_EMAIL`, `WEBUI_ADMIN_PASSWORD`), rclone (`CLOUDIFY_RCLONE_REMOTE_*`), restic (`RESTIC_PASSWORD`), etc. — all required touching cloudify core. This does not scale.

### Design constraint

`envsubst` with an explicit allow-list is intentional and must stay. Without it, `envsubst` would expand *every* `$VAR` in the template — including ones like `$HOME`, `$(...)`, and backticks that must resolve on the remote side, not locally. The allow-list is the security boundary.

### Proposed fix: `.remote-vars` convention

Each package declares its own remote vars in a file inside its directory:

```
pkg/open-webui/.remote-vars
pkg/rclone/.remote-vars
pkg/hermes-openwebui/.remote-vars
```

Format: one var name per line, comments allowed:

```
# pkg/open-webui/.remote-vars
WEBUI_ADMIN_EMAIL
WEBUI_ADMIN_PASSWORD
```

`cloudify_remote_sync()` would then:
1. Resolve which packages are being installed (already known at dispatch time)
2. Scan each package directory for `.remote-vars`
3. Collect all var names into a single deduplicated list
4. Dynamically build the `export` lines and the `envsubst` allow-list

The core vars (`CLOUDIFY_REMOTE_USER`, `CLOUDIFY_REMOTE_PWD`, `DEBUG`, etc.) would stay hardcoded in the template — they're infrastructure, not package-specific.

**Benefits:**
- Packages are self-contained — add a `.remote-vars` file, no core changes needed
- No silent failures — if a var is declared but not set locally, we can warn
- The allow-list security boundary is preserved
- Package authors can work independently without touching cloudify core
