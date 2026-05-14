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
