# Cloudify Roadmap

## Error aggregation in `cloudify_install_package`

`cloudify_install_package()` in `lib/packages.sh` calls `pkg_depends "$pkg"` in a loop, one package at a time. With `set -e` active, the first failure aborts the entire function — remaining packages are never attempted, and no error report is printed.

This is inconsistent with the design principle that **error aggregation belongs at the orchestration level**. `pkg_depends` already collects errors within a single call, but `cloudify_install_package` doesn't benefit from it when installing multiple packages (e.g. `cloudify install foo bar baz`).

**Proposed fix**: Apply the same error-collection pattern — continue through failures, collect failed package names, report comprehensive list at end.
