# Roadblocks

Issues discovered during e2e testing that need to be resolved in a future session.

## 1. `set -e` false positive in `cloudify_init_paths`

**Location:** `cloudify:102` (inside `cloudify_init_paths`)

**Problem:** The PATH check used a `&&` chain:
```bash
[[ ":${PATH}:" != *":${CLOUDIFY_LOCAL_BIN}:"* ]] && export PATH="${PATH}:${CLOUDIFY_LOCAL_BIN}"
```
When `~/.local/bin` is already in PATH (common on the local machine), the `[[ ]]` returns 1, the `&&` short-circuits, and `set -e` interprets the non-zero return as a fatal error. The script silently exits without any output.

**Status:** Fixed in commit `ca78e2d` — replaced with an `if` statement.

**Verification needed:** Confirm the fix handles all edge cases (PATH already set, PATH not set, massive PATH with special characters).

---

## 2. `cloudify_init_paths` called locally for remote operations

**Location:** `cloudify:411`

**Problem:** When running `cloudify --on hermes install hermes`, the `--on` handler calls `cloudify_init_paths` on the **local** machine (line 411):
```bash
[[ "$hosts" != "localhost" ]] && { _cloudify_require_remote_creds; cloudify_init_paths; }
```
This writes the `~/.local/bin` PATH to the **local** `~/.profile`, not the remote one. The remote host gets its own `cloudify_init_paths` call via the SSH payload, but the local call is wasteful and has side effects.

**Impact:** The local `~/.profile` gets a cloudify PATH block that it may not need. More importantly, this confused the investigation — we were checking the remote `.profile` while the code was writing to the local one.

**Proposed fix:** Skip `cloudify_init_paths` when the target is a remote host. The remote payload already handles it. Only call `cloudify_init_paths` for `localhost` operations:
```bash
[[ "$hosts" == "localhost" ]] && cloudify_init_paths
```
Or move the call to `_cloudify_execute_package_action` which already gates on localhost.

**Status:** Not yet fixed.

---

## Bonus: `cloudify exec` uses non-login SSH shell

**Problem:** `cloudify exec hermes "hermes --version"` runs `ssh root@hermes 'hermes --version'` — a non-login, non-interactive shell. Neither `~/.profile` nor `~/.bashrc` (past the `[ -z "$PS1" ] && return` guard) is sourced. So executables in `~/.local/bin` are not on PATH.

**Workaround:** `ssh root@hermes 'bash -l -c "hermes --version"'` works because `bash -l` sources `~/.profile`.

**Proposed fix:** Change the SSH command in `cloudify_remote_sync` to wrap remote commands in `bash -l -c`.

**Status:** Not yet fixed.
