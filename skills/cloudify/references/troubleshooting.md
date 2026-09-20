# Troubleshooting

## Logs first

Every install (local or remote) tees to `$CLOUDIFY_TMP/logs/<timestamp>.log` (default `/tmp/cloudify/logs/`). On any host failure the final message names the file. **Read it before guessing.** The log dir persists across runs.

## Remote repo stale

Remote hosts pull from **GitHub**, cached `CLOUDIFY_UPDATE_DELAY` (30 min). Force a fresh pull:

```bash
CLOUDIFY_FORCE_UPDATE=true cloudify --on host install pkg
# or
cloudify --on host exec 'cd ~/cloudify && git pull'
```

**Did you `git push`?** Unpushed changes never reach a remote host.

## `--on` silently ignored

`--on <host>` must precede the verb: `cloudify --on host install pkg`. Placed after, it runs locally.

## Verification fails / hangs

- Raise timeout in `~/.config/cloudify/pkgs/<pkg>.yaml`: `PKG_VERIFY_TIMEOUT: 120`
- Isolate: `cloudify --no-verify install <pkg>`
- Verify-only: `cloudify verify <pkg>`
- `verify.sh` runs in a clean subshell — reading recipe locals fails. Read env vars / config files only.

## Credentials not forwarded

```bash
cloudify credentials --check
```

- Package vars: `~/.config/cloudify/pkgs/<pkg>.yaml` (forwarded only with `--on`).
- Always-forward vars: `~/.config/cloudify/remote-vars.yaml`.
- Env vars override all config files.
- Automation: `export CLOUDIFY_SKIPCREDENTIALS=true`.

## Full debug

```bash
DEBUG=true cloudify --on host install pkg     # keep ALL temp files, verbose
CLOUDIFY_LOG_LEVEL=DEBUG cloudify ...
```

## sudo prompts hang

Shadow `sudo` reads the password from `CLOUDIFY_REMOTE_PWD`. Set it: `cloudify credentials remote`.

## Host key warnings

Expected — cloudify uses `StrictHostKeyChecking=no` (containers churn host keys). Safe on Tailscale/Incus; for production, pre-populate `~/.ssh/known_hosts`.

## cloudify not found

Not on PATH. Do not self-install — ping your human (see SKILL.md).
