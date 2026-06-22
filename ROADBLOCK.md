# Roadblocks

Issues discovered during e2e testing that need to be resolved in a future session.

## Separate-containers topology: DNS resolution (UNVERIFIED - recheck before acting)

### Symptom
`cloudify install` in separate-containers mode (open-webui on one host, hermes API on another, via Tailscale MagicDNS) is believed non-functional at the network layer.

### Stored reasoning (ZERO TRUST - recheck every claim)
The tension: open-webui Docker container needs BOTH public DNS (huggingface.co for model download, google.com generally) AND MagicDNS (hermes.ts.net for the API). One container, seemingly one resolver.

Hypothesized resolution (from Tailscale issues #14467, #12108, #18600):
1. Docker container inherits host `/etc/resolv.conf` when NO `dns:` directive is set.
2. systemd-resolved scopes `100.100.100.100` to the `tailscale0` interface, MERGING with the public resolver (per-interface DNS, not global override).
3. Tailscale 1.66+ stateful filtering drops Docker-range (172.17.x.x) packets to 100.100.100.100; fix = `tailscale set --stateful-filtering=false` on the host.
4. Cloudify's `dns: [100.100.100.100]` directive (removed in commit ee028af) was the CAUSE of breakage (overwrote the host merge inside the container), not a correct separate-containers setup.
5. `RAG_EMBEDDING_ENGINE=openai` (set when OPENAI_API_BASE_URL is) routes embeddings through the API, eliminating the huggingface.co download (the public-DNS need that ee028af's commit message names).

### Recheck before acting
- Verify each claim against current Tailscale docs + the cited issues (still open? still accurate in 2026?).
- Verify open-webui has NO other public-DNS dependency (telemetry, update checks, OAuth, lazy fetches).
- Verify by DOING a separate-containers install, not just reading code.
- Confirm conclusion: dns directive stays removed; separate-containers needs host-level Tailscale setup (MagicDNS on, systemd-resolved scoping, stateful filtering off) -> ivps/host-provisioning concern, not a cloudify pkg concern.

### Sources (re-read, don't trust the summary)
- tailscale/tailscale#14467
- tailscale/tailscale#12108
- tailscale/tailscale#18600
- https://tailscale.com/docs/reference/dns-in-tailscale
- cloudify commit ee028af (the dns removal)

---

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
