# Cloudify — Session History

## 2026-08-20 — deepseek-harness lifecycle tests complete

- **Validation closed**: `task test-unit` passed all 305 tests in `cloudai:cloudify`; `task lint` passed shellcheck for all recipe phases, including `install.sh` and `configure.sh`. No files were published to the production dsh instance; testing used only the cloudify container.

## 2026-08-20 — deepseek-harness split: configure = update verb (ADR-014)

- **Split applied (ADR-008 / ADR-014)**: `init.sh` → `install.sh` (guarded first install) + new `configure.sh` = the unguarded update phase. `cloudify configure deepseek-harness` = update to npm latest: bump, re-apply plugins (proven idempotent live), refresh unit (stable `ExecStart=/usr/local/bin/dsh`, kills the node-version-move break), restart, old→new + rollback hint. Verify hook runs after and gates the update.
- **Token preservation**: install generates `reverse-proxy.json` only if missing (`--clear-data` still regenerates+wipes); configure never touches it. Sessions survive FORCE re-installs and every update. Verified: token byte-identical through a simulated configure.
- **verify.sh hardened**: adds token file (0600, 64-hex) + served-index plugin-tag checks (`data-plugin="dsh-loopback-pin"` + `dsh-reverse-proxy`) — catches version drift that silently drops a plugin from the profile.
- **Tests**: new `tests/unit/deepseek-harness.bats` (8 tests, PATH-shim stubs — nothing real installed): 6/8 green in-container; 2 configure tests had test-env bugs (dispatcher resolves recipes in the temp sandbox, missing pkg/ → tests now source directly from `CLOUDIFY_SCRIPT_DIR`; leaked unit file in setup now hermetic). Local sim verified: npm bump call, token preservation, die-on-missing-pin. Full container rerun PENDING — cloudai unreachable (see below).
- **Taskfile lint glob** widened to cover `pkg/*/install.sh` + `pkg/*/configure.sh` (the rename had dropped them).
- **INFRA (not chased, but blocking tests)**: workstation's tailnet data path died mid-session — Windows Tailscale daemon wedged (service "Running" but CLI/powershell interop hang on `UtilAcceptVsock accept4 failed 110`; WSL eth1 has routes, tunnels dead). Both cloudai and dsh unreachable from the workstation; phone still reaches dsh (network fine). ACL verified intact: live policy = Aug 9 snapshot + lighthouse additions only; hermes grants present; a redundant `tag:workstation→tag:node` grant attempt was a true no-op (row already had the tag). Fix = restart Windows Tailscale (tray or elevated).

## 2026-08-20 — dsh-loopback-pin: accessor-based isLoopback pin (replaces sed; ADR-013)

- **Live diagnosis, root cause found**: remote Settings → Models failed ("settings are unavailable in this browser") on dsh rc.7. dsh-full-remote's page-bootstrap wraps `loader.load` once, but the shipped runtime REASSIGNS `load` to a thin `registration => this.register(registration)` arrow afterwards — silently clobbering the wrap (marker `__dshFullRemoteTrusted` survives, wrapper doesn't). Proven live in a headless browser: loader marked wrapped yet `load.toString()` is the 59-char arrow; instrumented diag sites never fired; connection module self-loads via `__ModuleLoader__.load` with the exact id the wrap looks for.
- **Decision (ADR-013)**: our own plugin, `dsh-loopback-pin`, installs an ACCESSOR on `loader.load` — getter always returns our intercepting function, setter captures reassignments as the new delegate — and wraps the connection module's factory to pin `connection.isLoopback = true` right after its apply (settings injects connection → Cordis orders it after). Survives dsh updates by construction. Replaces the sed patch (removed from recipe; bundle pristine, `isLoopback: pageLocation` intact).
- **Verified end-to-end live**: all three console markers fire (accessor installed → connection module intercepted → isLoopback pinned); Settings → Models renders the provider directory (DeepSeek card, API key configured) with NO error.
- **Plugin shipped inside the pkg** (`pkg/deepseek-harness/dsh-loopback-pin/`), recipe copies to `/opt/dsh-loopback-pin` + `dsh plugin --profile web add` (local path); registered as profile bundle. Committed `7f235b6`, pushed.
- **Ops**: smartphone (Redmi 14C) lost `tag:mobile` (known ivps tag-stripping bug, not chased now — second device after the workstation); re-added via Tailscale API. Untagged + authkey-registered devices match neither `autogroup:member` nor their tag → TCP dropped while app ping (disco) still works.

## 2026-08-10 — deployments branch rebased on master + §5.1 fix (CRITICAL GATE completed)

- **Gate artifacts produced** (in ~/tmp/cloudify-deployments-gate/): `bash-magic.md` (subagent 1 — the bash magic end-to-end: forwarding, shadows, router, 16 invariants, composition points) and `rebase-analysis.md` (subagent 2 — grounded rebase analysis in a scratch worktree: rebase clean, 16-invariant verdicts, §5.1 confirmed).
- **§5.1 CONFIRMED + FIXED**: deployment-wide vars died in a $() subshell — names reached the envsubst allow-list but values never exported, payload carried `export K3S_TOKEN=''`. Fix: run the deployment read in the parent shell, capture names via temp-file redirect, snapshot/restore already-claimed env values (first-write-wins preserved). Verified by real payload probe: plain → `K3S_TOKEN='real-value'`; overlap → `'pkg-value'` (per-pkg wins); full unit suite 289/289 incl. deployments.bats 23/23.
- **Two subagent claims CORRECTED by empirical probe**: the "pre-existing deps-grep abort" and the §5.3 post-fix fail-fast are NOT live — the router calls `cloudify_remote ... && is_setup_in_progress=true` (cloudify:283-284), an `&&` list, which disables errexit for the whole dispatch including the backgrounded subshell. Real installs of dep-less recipe pkgs (pandoc, bat) succeed on master. The abort only fires in bare-call contexts (tests/probes). Addendum appended to rebase-analysis.md.
- **feat/deployments rebased onto master** (consent-gated): clean replay of the 2 feature commits + fix commit (e0f68b4). Branch pushed.
- **State:** deployments = deployment-wide store + `cloudify vars set/delete/show/list` (+ --stdin/--file) + `CLOUDIFY_DEPLOYMENT` context + TOKEN/KEY debug masking. Next: user-gated merge to master, then the k3s e2e-with-deployments validation (live run: token from the store, not the env).

## 2026-08-06 — ADR-011: deployments = applications (cloudify-owned), deployment-first state shape

- **Decision recorded** (ADR-011): a deployment is a first-class cloud-global entity — an application across nodes; a k3s cluster is a deployment. Supersedes ADR-006's packages-first sub-shape: per-node slices become `nodes/<node>/deployments/<id>/pkgs/<pkg>/config.yaml`; deployment-wide state lives at `~/.config/cloudify/deployments/<id>/` (fixed-path convention, ivps stays opaque). Ownership: cloudify owns applications, ivps owns resources. Context is a per-shell `CLOUDIFY_DEPLOYMENT` env var (no open/close, no shared context file — parallel-safe). `cloudify vars set/delete/list` + `cloudify deployment list/delete`; precedence caller-env > per-(node,pkg) > deployment-wide; secrets-as-config for MVP; debug masking extended to TOKEN/KEY.
- **Spike-proven ivps F1 gap (reported for ivps fix)**: `ivps tag create` grants use `autogroup:member`, but every tailnet device is tagged (15/15), so the operator (tag:workstation) gets no access to new tags — nodes unreachable (no netmap/DNS/SSH) until a `src:[tag:workstation]` grant is added manually. Verified live: adding the grant restores connectivity instantly. Also corrects ADR-010's operator-reach wording. Blocked the k3s multi-cluster e2e.


## 2026-07-31 — cloudify-hermes SKILL.md: drop stale launch-wait retry loop (separable follow-up)

- Removed the post-`ivps launch` wait-for-SSH retry loop from `~/.agents/skills/cloudify-hermes/SKILL.md` — ivps blocks until SSH-ready since 2026-06-14 (ivps issues #1/#2). Kept the "SSH fails after launch" troubleshooting section (failure diagnosis, not a redundant wait). The second separable item (ACL jq-on-huJSON bug) was already fixed during the spike (ADR-010).


## 2026-07-31 — C2: install/run split — install.sh + configure.sh, `cloudify configure` (issue #6, ADR-008)

- **Implemented** optional split: `pkg/<name>/install.sh` (idempotent bits + install guard) + `configure.sh` (run phase, no guard). Split pkgs: `cloudify install` runs install.sh THEN configure.sh; new `cloudify configure <pkg>` runs configure.sh only (cheap secret rotation, no re-download); non-split pkgs error clearly; `init.sh`-only pkgs install exactly as before (regression-tested). Verify-hook (ADR-004) runs after both.
- **Recipe resolution generalized** (`cloudify_package_recipe_path`): install.sh preferred when present, init.sh legacy fallback; optional filename arg resolves configure.sh (`cloudify_package_configure_path`). `_cloudify_source_pkg_phases` sources both phases in one subshell; `pkg_depends` uses it for deps too.
- **`_cloudify_pkg_remote_vars`** now collects package vars for configure dispatches too (k3s token rotation forwards `K3S_TOKEN` via `.remote-vars`, C1).
- **Red spec**: `tests/unit/install-run-split.bats` (7) + E2E `tests/integration/package-install-run-split.bats` (7, incl. init-only byte-identical regression + verify-after-configure failure path). Fixtures `pkg/fixture-split/` (install+configure+verify+.remote-vars) and `pkg/fixture-legacy/`.
- **PR #10 opened** (feat/install-run-split, stacked on feat/remote-vars). task test-unit 260/260 + lint green.


## 2026-07-31 — C1: pkg .remote-vars — names in repo, values from caller env (issue #5, ADR-007)

- **Implemented** `pkg/<name>/.remote-vars`: declares var NAMES in the repo; values come from the caller's env at install time (`_try_claim_env` in lib/remote.sh). Env wins over disk for the same name; global `remote-vars.yaml` + per-pkg yaml stay as back-compat reads; declared-but-unset names warn and are not forwarded.
- **Parallel-safe by construction** (no shared file): red spec `tests/unit/remote-vars.bats` (7 tests incl. parallel no-shared-file regression) + E2E `tests/integration/package-remote-vars.bats` (two containers, concurrent installs of the same fixture pkg, each host received its own token).
- **Pre-existing bug fixed**: `trap ... RETURN` in `_cloudify_pkg_remote_vars` fired on nested function returns under functrace (`set -T`, which bats uses) — deleted the temp var list mid-walk, breaking every claim. Guarded by FUNCNAME. Production never hit it (no functrace); tests would have.
- **Test infra**: gettext-base (envsubst) added to `setup-container` + `itest-base` tasks; itest-base snapshot recreated.
- **PR #13 opened** (feat/remote-vars). `task test-unit` + lint green; `task test` green modulo pre-existing master failures (package-hunk: npm -g bin not on ssh PATH under mise node; package-hermes-dashboard/-openwebui: hermes pkg_depends install fails in test container) — all reproduced on master worktree.


## 2026-07-31 — k3s multi-cluster design + ADR.md created (plan: k3s-multi-cluster)

- **Design session**: k3s multi-cluster provisioning on the cloudify/ivps private cloud. Full design + grounding in `scratchpad/ivps-cloudify-evolutions-proposal.md`; plan in `tmp/plans/k3s-multi-cluster.md` (PLAN.md repointed from completed pkg-verify-hook plan).
- **Decisions recorded as ADR-006 through ADR-009** (new `ADR.md` — backfilled ADR-001..005 from prior HISTORY since the project lacked an ADR file; constitution-required).
  - ADR-006: node-keyed state registry under ivps (`nodes/<node>/pkgs/<pkg>/deployments/<id>/`); cloudify writes opaque state, ivps owns node lifecycle. Supersedes ADR-002 storage location.
  - ADR-007: `pkg/<name>/.remote-vars` (names in repo, values from caller env) — parallel-safe forwarding. Names-vs-values split holds from ADR-002.
  - ADR-008: install/run separation (`install.sh` + `configure.sh`, init.sh back-compat, new `cloudify configure` verb). k3s is first split pkg.
  - ADR-009: per-cluster tailnet tags (`tag:k3s-<cluster>`) for network isolation. ivps deltas: `tag create/delete/list`, `launch --tag`.
- **MVP CNI**: flannel VXLAN, MTU 1230 (overlay-in-overlay: tailscale 1280 - VXLAN 50; grounded via exa: tailscale#8219/#16820, flannel#1011). Tailscale CNI (drop VXLAN) + HA control plane tracked in ROADMAP as follow-ons.
- **Constitution correction**: retracted an earlier proposal that `ivps launch` should block until SSH-ready — already shipped 2026-06-14 (ivps issues #1/#2, `IVPS_WAIT=1`). Lesson reinforced: never propose a delta without a disproof attempt; skill summaries are entry points, not evidence.
- **Stale artifact found**: `cloudify-hermes` SKILL.md contains a launch-wait retry loop written 2026-06-13, one day before ivps launch became blocking. Defect via staleness, not a missed purpose (verified by mtime vs ivps git log). Separable follow-up: drop the loop from the skill.
- **Roadmap**: applied stashed `cloudify packages` one-liner-description proposal to ROADMAP. Added k3s HA + Tailscale CNI entries.
- **Spike run (same day): GREEN — gate passed.** 2 throwaway incus nodes as `tag:k3s-spike`, k3s v1.33.3+k3s1 server+agent; both nodes Ready, cross-node pod ping + 8MB TCP OK. ACL restored to pristine (incl. comments), nodes deleted, authkey revoked. Findings recorded as **ADR-010**: mesh (ADR-009) validated; ACL `tag create` is ATOMIC (one POST: tagOwners + ssh.dst + grants) — a grant resolves against tagOwners alone, no node needed (corrected post-spike: the earlier "3-phase" claim was a misdiagnosis; the spike 400 was the port-wildcard grants syntax, not tag existence); `grants` dst is host-only with ports in `ip` (NOT `tag:X:*`, the legacy `acls` form); operator-reach grant src is `autogroup:member` not `tag:workstation`; k3s recipe MUST set `--flannel-iface=tailscale0` (else flannel VTEP uses the incus bridge IP → 100% pod loss) and `--kubelet-arg=feature-gates=KubeletInUserNamespace=true` (else kubelet crashes on /dev/kmsg in unprivileged incus); MTU 1230 optional not required (default 1450 transfers 8MB TCP in 3s — PMTUD absorbs the mismatch); ACL `If-Match` opt-in but enforced (omit=unconditional; garbage=412); etag via GET `-D` not HEAD.
- **hermes skill bug fixed**: `cloudify-hermes` SKILL.md ACL block ran `jq` on huJSON (comments break `jq` parse) → now GETs with `Accept: application/json`. Latent — broke on any ACL containing comments.

## 2026-07-31 — k3s plan brought to project standard (issues filed, task-list restructure)

- The design plan was phased-narrative, not a trackable task plan; it hoarded issues as local markdown and carried no TDD/container-SDLC content for the code phases — three violations of project AGENTS.md ("issues on GitHub, not local markdown"; plans reference issues; TDD-in-container).
- **Issues filed (7):** ivps #9 (`tag create/delete/list`), #10 (`launch --tag`), #11 (`node-as-dir` + `node path`); cloudify #5 (`.remote-vars`), #6 (install/run split), #7 (state-registry write), #8 (k3s recipes).
- **Plan restructured** (`tmp/plans/k3s-multi-cluster.md`): each phase is now checkable tasks (`- [ ]`) keyed to issue numbers; each code task carries a red bats spec + `task test` gate (Testing Trophy); `## Issues to file` (local text) replaced with `## Issues` (GitHub links); a `## Working discipline` section makes the TDD/container/push-before-tests/per-phase-gate rules explicit and inherited by every task.
- **Dependencies made explicit:** C3 [#7] blocks on F3 [#11]; C2 [#6] blocks Phase 3 [#8]; F1/F2 + C1/C2 parallelizable.

## 2026-07-05 — youtube-mcp package: MCP server for YouTube data

- **New package**: `pkg/youtube-mcp/` — Streamable HTTP MCP server serving YouTube video info, comments, transcripts, search, and transcript languages. No YouTube API key needed (uses youtubei.js + youtube-transcript-plus).
- **Source**: `github.com/rachidbch/youtube-mcp` (fork of granitebps/youtube-mcp with session-registration fix + trust proxy).
- **Architecture**: Node.js via mise (>=20 required), systemd service on port 8443, bearer token auth. Token auto-generated on first install, displayed via SSH output for user to save to `pkgs/youtube-mcp.yaml`.
- **Key recipe decisions**:
  - `pkg_depends mise` but node installed directly via `mise use -g node@lts` (avoids `pkg_depends node` guard skip when apt node already present at depth>0).
  - Absolute path to mise shim in systemd ExecStart — `Environment=PATH` doesn't work for ExecStart resolution in LXC containers.
  - `#linux` platform tag (systemd-dependent).
- **Deployed**: `cloudai:youtube-mcp-2`, exposed via Tailscale Funnel at `https://youtube-mcp-2.komodo-everest.ts.net`.

## 2026-06-22 — separate-containers DNS: conditional dual-dns + peer-visibility root cause (fix/openwebui-conditional-dns)

- **Trigger**: ROADBLOCK.md flagged separate-containers (open-webui <-> hermes via MagicDNS) as non-functional, unverified. Zero-trust recheck requested.
- **Live testing** on `cloudai:hermes` + `cloudai:openwebui-hermes` (raw UDP DNS + docker dual-NS containers):
  1. quad100 (`100.100.100.100`) resolves `*.ts.net` but **SERVFAILs public domains** in this tailnet (no global nameservers configured). ee028af's stated root cause was correct.
  2. glibc + musk **fail over on SERVFAIL** -> `dns: [100.100.100.100, 1.1.1.1]` serves both MagicDNS and public from one resolver block. Verified green against visible peer `hermes-svc` + `huggingface.co`.
  3. The **actual end-to-end blocker** is NOT DNS: `cloudai:hermes` (tag:incus) is invisible to `cloudai:openwebui-hermes` (tag:incus) - NXDOMAIN, absent peer list, ping fails. MagicDNS only resolves *visible* peers. `hermes-svc` (tag:incus, 8d, has `~/.hermes/.env`, serves API) IS visible.
- **Fix (pkg layer)**: `pkg/open-webui/init.sh` now emits a conditional `dns:` block when `OPENAI_API_BASE_URL` is a `*.ts.net` URL (separate-containers topology); no directive otherwise (in-container topology inherits host DNS, `host.docker.internal` is a static entry). New `CLOUDIFY_OPENWEBUI_FALLBACK_DNS` (default `1.1.1.1`). Heavy commenting on the non-obvious bits (why dual NS, why quad100 SERVFAILs, visibility prerequisite).
- **Docs**: `pkg/open-webui/README.md` + `pkg/hermes-openwebui/README.md` corrected (was stale: single `dns: 100.100.100.100`, which re-breaks huggingface); ROADBLOCK.md reframed with verified layered truth.
- **Escalated (human decision, NOT code)**: backend node = `hermes` (needs ACL fix) vs `hermes-svc` (already visible + serving). Stale/partial ACL suspected - `hermes-svc` visible but `hermes` not, both tag:incus.

## 2026-06-20 — Fix local-install password failure: local credential section (#1)

- **Root cause**: On the local install path, `CLOUDIFY_HOSTPWD` was mapped only from `CLOUDIFY_LOCAL_PWD` (`cloudify` main), and **nothing ever set `CLOUDIFY_LOCAL_PWD`** — the credentials framework only knew remote/github/gitlab. So the first sudo-needing `@default` died with `Password not set for user rbc`.
- **Fix**: Added a `local` section to `lib/credentials.sh` — `cloudify_ask_local_credentials`, `local` cases in `cloudify_credentials_save`/`_check`/`_setup` (password-only — the local user is always `whoami`), included in the all-sections save. Router (`cloudify`): `credentials local` subcommand + usage line. `main()`'s existing `${CLOUDIFY_LOCAL_PWD:-}` → `CLOUDIFY_HOSTPWD` mapping now resolves.
- **Tests**: `tests/unit/credentials.bats` — new "saves only the local section" test; `cloudify_ask_local_credentials` in the defined-functions test; `CLOUDIFY_LOCAL_PWD` set + asserted in the "all OK" check.
- Lint clean (`shellcheck -x` on `lib/credentials.sh`, `cloudify`).

## 2026-06-20 — apt-get shadow: no sudo on no-op installs (cache pre-pass)

- **Problem**: `lib/shadows/apt-get.sh` ran `_cloudify_apt_cache_stale && sudo apt-get update` **before** the per-package `dpkg -l` idempotency check, so a stale cache (>60min) demanded a password even when every requested package was already installed.
- **Fix**: Pre-pass refreshes the apt cache only when ≥1 package is genuinely missing (`_cloudify_pkg_installed`). Strict improvement — when something IS missing, behavior is identical to before; when all installed, no sudo at all. Independent of the local-credential fix (the password is still needed for genuinely-missing packages).
- Lint clean (`shellcheck -x` on `lib/shadows/apt-get.sh`).

## 2026-06-20 — Clean failure when a @default aborts the requested install (#4)

- **Problem**: `cloudify install <pkg>` installs the `@default` set **synchronously** before the user's package. The native-manager path (`pkg_apt_install`, when a package has no recipe) in `pkg_depends` was NOT wrapped in a subshell, so a `die` (e.g. sudo shadow `Password not set for user rbc`) called `exit` and killed the whole process — `failed_packages` never recorded it, no `Failed packages:` summary printed, and the user's explicitly-requested package was never attempted. The user saw a bare error + exit 1 with no indication that (a) it was a `@default` that failed and (b) their package was skipped. (The recipe path was already isolated in a subshell; only the native path leaked.)
- **Fix**: `lib/package-api.sh` — wrap both native-path `pkg_apt_install` calls in subshells (`if ! ( pkg_apt_install "${pkg}" )`), matching the recipe path, so `die`'s `exit` is contained, the failure is recorded, the loop continues, and the summary prints. `cloudify` — check the synchronous `cloudify_install_package $defaults` return: on failure, print a clear message naming the failure and stating the requested package was NOT attempted, with the remediation (`--no-defaults`), then exit 1.
- **Test**: `tests/unit/package-api.bats` — new "isolates native-path failures (die/exit) in subshell" regression test (mocks `pkg_apt_install` to `exit 1`, asserts the package is recorded in `Failed packages:` and subsequent packages are still attempted).
## 2026-06-14 — `pkg_verify` hook: script-friendly verification (Issue #2)

- **Feature**: `cloudify install` now blocks until each installed package is verified (or fails clearly). No more manual `ssh`/`curl` after install returns.
- **Design** (see `tmp/plans/pkg-verify-hook.md`): optional `pkg/<name>/verify.sh` defining `pkg_verify()`, sourced in a clean subshell by `_cloudify_run_verify` (retry loop, `${PKG_VERIFY_TIMEOUT:-30}s`). Deep-verify runs after every package incl. deps.
- **Why a separate `verify.sh` (not inline)**: both install+verify and verify-only paths source it in an identical clean-subshell environment (exported env + on-disk config only). Kills the sed-extraction fragility and environment-asymmetry that an inline `pkg_verify()` would have caused.
- **CLI**: `--verify` (verify-only), `--no-verify` (skip), `cloudify verify <pkg>` subcommand. Per-host failure reporting in parallel multi-host installs. **Exit code now non-zero if any host fails** (previously always 0 — pre-existing bug fixed as the plan requires "fails clearly").
- **Authoring contract (constraints a/b)**: parent overriding a dep via env var → declare in parent `pkgs/<pkg>.yaml`; parent hardcoding a dep rewire → parent's `verify.sh` owns that check (dep must not assert on it).
- **Behavior change**: existing non-fatal `log_warn` health checks in `hermes-openwebui/init.sh` moved to `verify.sh` — they are now **fatal/blocking** by design.
- **Files**: `lib/package-api.sh` (`_cloudify_run_verify`, `cloudify_package_verify_path`, deep-verify call in `pkg_depends`); `cloudify` (flags, `verify` subcommand, per-host reporting); `lib/remote.sh` (forward `CLOUDIFY_NO_VERIFY` + `PKG_VERIFY_TIMEOUT`, verify-only dispatch, host tracking); new `pkg/hermes/verify.sh`, `pkg/hermes-dashboard/verify.sh`, `pkg/hermes-openwebui/verify.sh`.
- **Tests**: 13 new unit tests (`_cloudify_run_verify` success/timeout/no-hook/retry/yaml-load + router flag/verify-subcommand). Lint clean incl. `pkg/*/verify.sh`. hermes-dashboard integration passes 4/4 with verify-on-by-default (real `pkg_verify` on a ~27s slow-starting service, `PKG_VERIFY_TIMEOUT=90`). hermes-openwebui integration 5/5 (`--no-verify` for fake-cred test env). open-webui now healthy (2026-06-11 roadblock resolved).

## 2026-06-14 — Fix subshell var forwarding + Hermes rebuild

- **Bug**: `_cloudify_pkg_remote_vars()` runs in command substitution `$()`, so its `export` side effects are lost. `envsubst` then substitutes empty strings for all pkg yaml vars. Symptoms: `WEBUI_ADMIN_*` defaults used instead of configured values, `CLOUDIFY_HERMES_API_URL` empty causing hermes-openwebui local-case fallback.
- **Fix**: Call `_cloudify_pkg_remote_vars` directly in parent shell, redirect stdout to temp file for name capture (identical API). Exports now survive for `envsubst`.
- Lint clean. All 237 unit tests pass. 9/29 integration pass (remainder time out — hermes install inherent slowness).

## 2026-06-14 — Hermes Unified Services Rebuild

Recreated `cloudai:hermes-svc` from scratch following the unified-services handoff recipe:
- Nuked `cloudai:hermes-svc` + cleaned up stale Tailscale device (caused hostname collision on relaunch)
- Launched fresh container, installed hermes + hermes-dashboard + hermes-openwebui
- Applied dashboard bind fix: `--host 0.0.0.0 --insecure --port 9119` (Host header rejection)
- Exposed 3 Tailscale Services: `svc:hermes-api` (:8642), `svc:hermes-dash` (:9119), `svc:hermes-owui` (:3000)
- ACL grants already correct from prior session (no changes needed)
- All services approved and verified: API 200, Dashboard 200, OpenWebUI 200

Final state:
| Service | URL | Port | Grant |
|---------|-----|------|-------|
| hermes-api | https://hermes-api.komodo-everest.ts.net/ | 8642 | tag:incus |
| hermes-dash | https://hermes-dash.komodo-everest.ts.net/ | 9119 | autogroup:member |
| hermes-owui | https://hermes-owui.komodo-everest.ts.net/ | 3000 | autogroup:member |

## 2026-06-13 — Recursive dependency var forwarding + guards + hermes-model

- **Fix A**: Rewrote `_cloudify_pkg_remote_vars()` in `lib/remote.sh` with recursive dependency walk, first-write-wins priority, and cycle guard. Now correctly forwards vars from transitive dependencies (e.g. `hermes-openwebui` → `open-webui` → `WEBUI_ADMIN_EMAIL`). Priority: `remote-vars.yaml` > rightmost-pkg > ... > leftmost-pkg > deps > deps-of-deps.
- **Fix B**: Restored install guards in `pkg/open-webui/init.sh` and `pkg/hermes-openwebui/init.sh`. Skips regeneration when compose file exists and FORCE/CLEAR_DATA are unset.
- **Fix C**: Created `pkg/hermes-model/init.sh` — configures LLM provider/model for Hermes via `~/.config/cloudify/pkgs/hermes-model.yaml`. Smart guard skips if provider+model already match. Supports deepseek, openrouter, novita, google, custom providers.
- Fixed pre-existing lint: removed `local` from top-level `env_block` in `open-webui/init.sh`.
- Fixed hermes-openwebui integration test: combined install into one command (guard was skipping the wire-up when open-webui was pre-installed).
- Fixed hermes-dashboard integration test: increased HTTP wait timeout (27s web UI build), added `-q` to all TEST_SSH definitions to suppress "Permanently added" stderr pollution in bats `run` output.
- Added constitution rule: never skip a test failure by dismissing it as pre-existing.
- All 237 unit + 29 integration tests passing.

- Previous `hermes-svc` container was gone. Recreated from handoff recipe.
- Discovered `hermes gateway install` has **two** interactive prompts (start now? + auto-start on boot?), no `--yes` flag.
- `pkg/hermes-openwebui/init.sh` local case fixed: `echo |` → `yes |` to answer both prompts.
- Install re-ran successfully: hermes-gateway (8642), hermes-dashboard (9119, `--host 0.0.0.0 --insecure`), open-webui (3000) all as systemd services.
- 3 Tailscale Services re-exposed: `svc:hermes-api`, `svc:hermes-dash`, `svc:hermes-owui`.
- ACL grants: `tag:incus → svc:hermes-api`, `autogroup:member → svc:hermes-dash,svc:hermes-owui`. Pushed via API with ETag.
- Services await admin approval at https://login.tailscale.com/admin/services.
- Created `~/.agents/skills/cloudify-hermes/SKILL.md` — reusable deployment skill covering all steps, edge cases (gateway foreground process, two-prompt install, ETag conflicts, dashboard Host header), idempotency, and troubleshooting.
- CLAUDE.md: added usage priority rule (cloudify > ivps > incus).

## 2026-06-13 — Remove repo-side remote-vars.yaml (single source of truth)

- `_cloudify_pkg_remote_vars()` now reads var names from `~/.config/cloudify/pkgs/<pkg>.yaml` instead of `pkg/<name>/remote-vars.yaml`.
- Deleted `pkg/open-webui/remote-vars.yaml`, `pkg/hermes-openwebui/remote-vars.yaml`, `pkg/hermes-signal/remote-vars.yaml`.
- `hermes-openwebui/init.sh`: local case restructured — `export OPENAI_*` before `pkg_depends open-webui`, eliminated `connect.sh`.
- READMEs updated: Configuration tables reference `~/.config/cloudify/pkgs/<pkg>.yaml`.
- AGENTS.md: added turn closure rule (docs updated + git clean).
- Unit tests: 231/231 passing.

## 2026-06-13 — Hermes Unified Services: 3 services, 1 container, svc: grants

- Container `cloudai:hermes-svc` created via ivps. Hermes + dashboard + openwebui installed via cloudify.
- 3 Tailscale Services exposed: `svc:hermes-api` (8642), `svc:hermes-dash` (9119), `svc:hermes-owui` (3000).
- ACL grants use `svc:<name>` destinations: `tag:incus → svc:hermes-api`, `autogroup:member → svc:hermes-dash,svc:hermes-owui`.
- Dashboard requires `--host 0.0.0.0 --insecure` to accept proxy Host header from Tailscale Service.
- 5 ivps bugs found + fixed (ordering, URL, addrs, curl body drop, serve reset nuke).
- Pattern proven: `ivps expose-service` + precise `svc:` grants for per-service access control.

## 2026-06-12 — Tailscale Services experiment (programmatic service creation)

- Goal: use Tailscale Services (`<service>.<tailnet>.ts.net`) to serve multiple
  services on a single container, replacing separate containers + SSH tunnels.
- Created service `svc:test` via Tailscale API from cloudify container:
  `PUT /api/v2/tailnet/{tailnet}/vip-services/svc:test`
- **Critical discovery**: API calls to api.tailscale.com must come from inside
  the tailnet — local machine can't reach it. Future ivps service management
  must route API calls through a tailnet node.
- Configured host with `tailscale serve --service=svc:test --https=443 localhost:8080`
- Service awaits admin approval at https://login.tailscale.com/admin/services
- Stored `TS_API_KEY` in `~/.config/ivps/config.env` alongside `TS_AUTH_KEY`
- Long-term: this pathway (service create → configure host → approve) should be
  an ivps feature, not cloudify. ivps owns Tailscale integration.

## 2026-06-12 — hermes-dashboard verified + yazi/ivps investigation

- Yazi integration test: written 2026-06-05 but never run (incus unreachable). Now passes 3/3.
- hermes-openwebui timeout claim: stale. Test was simplified (065c67f, dad00d4), no longer needs tailscale at runtime. Passes 6/6.
- hermes-dashboard: reinstalled on cloudai:hermes. Stale Jun-11 process held port 9119,
  old relay.py unit replaced. Dashboard serves HTTP 200 on loopback :9119.
- ivps tunnel: TS_DOMAIN split fixed (64d3f67), ((count++)) bug fixed (e51e1b3).
  `ivps tunnel start cloudai:hermes 9119:9119` works end-to-end.

## 2026-06-12 — Update CLAUDE.md Architecture section

- Updated package count: 65+ → 75+
- Added repo-side `pkg/<name>/remote-vars.yaml` interface distinction
  (repo yaml = interface, user yaml = values)
- No other sections touched

## 2026-06-12 — Fix word-splitting bug in _cloudify_pkg_remote_vars

- Root cause: `_cloudify_dispatch` passes `$packages` as a single string
  `"--install pkg1 pkg2"` to `cloudify_remote`. The function used quoted `"$@"`
  which preserved this as one argument, so the `--install` flag was never
  detected and no package vars were collected.
- Fix: `local args=($@)` (unquoted) triggers word-splitting, correctly
  separating `--install` from package names.
- hermes-openwebui integration test now passes 6/6 with env var exports
  (no file writes to ~/.config/cloudify/credentials).

## 2026-06-12 — Per-package user config via ~/.config/cloudify/pkgs/<pkg>.yaml

- New `lib/pkg-config.sh` module: `_cloudify_load_yaml_vars()` parses flat key:value YAML
  and exports vars into the environment. Overrides existing env vars (package config
  is authoritative).
- Architecture:
  - `~/.config/cloudify/credentials` — system auth only (remote, github, gitlab)
  - `~/.config/cloudify/remote-vars.yaml` — vars ALWAYS forwarded on every `--on` call
  - `~/.config/cloudify/pkgs/<pkg>.yaml` — vars forwarded only when installing `<pkg>`
- `_cloudify_pkg_remote_vars()` in `lib/remote.sh` now loads config from user yaml files
  before collecting var names from repo `pkg/<name>/remote-vars.yaml`. Also includes
  always-forward vars from `~/.config/cloudify/remote-vars.yaml`.
- Repo yaml files define the interface (which vars are required). User yaml files
  provide the values. No backward compat with pkg vars in credentials file.
- Updated bats test: exports fake `CLOUDIFY_HERMES_API_URL`/`CLOUDIFY_HERMES_API_KEY`
  directly in test file (no file writes).

## 2026-06-12 — Refactor remote var forwarding to per-package yaml files

- Removed hardcoded package-specific `export` lines and `envsubst` entries from `lib/remote.sh`.
  Replaced with per-package `pkg/<name>/remote-vars.yaml` files (key-value, var names extracted via grep).
- Core infrastructure vars (CLOUDIFY_REMOTE_USER, DEBUG, etc.) stay hardcoded in remote.sh.
- `_cloudify_pkg_remote_vars()` scans yaml files for requested packages, generates template
  exports and envsubst list dynamically.
- Fixed `declare -f` stripping comment-based placeholder → used `: _CLOUDIFY_PKG_EXPORTS_` no-op.
- `pkg/hermes-openwebui/remote-vars.yaml`: CLOUDIFY_HERMES_API_URL, CLOUDIFY_HERMES_API_KEY
- `pkg/open-webui/remote-vars.yaml`: CLOUDIFY_OPENWEBUI_PORT, CLOUDIFY_OPENWEBUI_BIND, WEBUI_ADMIN_EMAIL, WEBUI_ADMIN_PASSWORD
- `pkg/hermes-signal/remote-vars.yaml`: CLOUDIFY_SIGNAL_PORT
- Commit: 35c8ddd

## 2026-06-11 — open-webui compose fixes and test stabilization

- Fixed missing trailing newline after heredoc in `pkg/open-webui/init.sh`:
  `env_block=$(cat <<INNER ...)` strips trailing newline → `${env_block}` in compose
  template ran into YAML `volumes:` key → broken compose. Fix: `env_block+=$'\n'`.
- Removed redundant `\n` in printf RAG line (now handled by trailing newline above).
- Extended health check timeout from 30→120 attempts (240s) for first-launch HuggingFace
  sentence-transformers model download.
- Commits: 0b70463, 83029b3
- Integration test `package-open-webui` now passes consistently (6/6).

## 2026-06-11 — RAG_EMBEDDING_ENGINE newline bug (known issue)

- `pkg/open-webui/init.sh` line 58: `$()` strips trailing newline from heredoc,
  so `printf '%s      - RAG...\n'` appends RAG line to same line as OPENAI_API_KEY.
  Fix: prepend `\n` in printf format or use a different append approach.
- Not yet deployed to container.

## 2026-06-11 — Remove connect-remote.sh, delegate to open-webui init

- Deleted `pkg/hermes-openwebui/connect-remote.sh` (79 lines). Its sole purpose
  (sed-update compose, restart, health wait) is now handled by `open-webui/init.sh`
  which always regenerates compose from env vars.
- `hermes-openwebui/init.sh` now exports `OPENAI_API_BASE_URL` + `OPENAI_API_KEY`
  from `CLOUDIFY_HERMES_*` before calling `pkg_depends open-webui`. Compose gets
  correct values directly — no sed, no separate restart.
- Added non-fatal hermes API health check.
- Updated integration test + README.
- Commit: 065c67f

## 2026-06-11 — Remove install guards from open-webui + hermes-openwebui

- Both `pkg/open-webui/init.sh` and `pkg/hermes-openwebui/init.sh` now always
  regenerate docker-compose.yml from current env vars on every run. Change
  credentials in `~/.config/cloudify/credentials`, re-run `cloudify --on`,
  compose picks up new values.
- Commits: dad00d4 (hermes-openwebui), 0c28d27 (open-webui)

## 2026-06-11 — Fix open-webui crash, complete separate-containers v2 deployment

- **Root cause:** Docker `dns: [100.100.100.100]` (Tailscale MagicDNS) can't resolve `huggingface.co`, so SentenceTransformer model download fails at boot. Empty `RAG_EMBEDDING_ENGINE=` still triggers default model loading.
- **Fix:** Removed `dns:` section from open-webui recipe (let Docker use host DNS via systemd-resolved stub). Added conditional `RAG_EMBEDDING_ENGINE=openai` when `OPENAI_API_BASE_URL` is set. Updated `connect-remote.sh` to ensure RAG_EMBEDDING_ENGINE is set.
- **Deployed:** open-webui on openwebui-hermes container is healthy (Up, healthy). tailscale serve exposes `https://openwebui-hermes.komodo-everest.ts.net`. API connectivity open-webui → hermes verified.
- **Commit:** ee028af — `pkg/open-webui/init.sh`, `pkg/hermes-openwebui/connect-remote.sh`

## 2026-05-19 — Document and apply install guard convention (E1, E2)

- **E1:** Added "Install Guards" subsection to README.md "Writing a Package Recipe" — documents software vs data distinction, FORCE/CLEAR_DATA vars, code pattern
- **E2:** Audited all 73 packages. Added install guards to 16 stateful packages: hermes-signal, restic, docker, rclone, mise, fzf, sdkman, miniconda3, bash-it, dotfiles, leanmacs, spacemacs, mariadb, mysql, wezterm, ufw
- Converted 4 ad-hoc skip checks to FORCE/CLEAR_DATA convention (mariadb, mysql, wezterm, ufw)
- Fixed inverted fzf clone/pull logic
- Files changed: 16 `pkg/*/init.sh`, `README.md`, `OPTIMIZATIONS.md`
- 237 unit tests pass, 26/27 integration tests pass (open-webui pre-existing flaky test)

## 2026-05-18 — Apply OPTIMIZATIONS.md decisions (A1, B1, C1, D1, A2, G1)

- **A1:** Replaced `exec >> log 2>&1` with `exec > >(tee -a log) 2>&1 </dev/null` in remote payload — output now visible on local terminal AND written to log file
- **B1:** Added `--clear-data` CLI flag → exports `CLOUDIFY_CLEAR_DATA=true`, passed through remote payload. Implies `CLOUDIFY_FORCE=true`
- **C1:** `CLOUDIFY_FORCE=true` set for explicitly dispatched packages; `pkg_depends()` unsets both `CLOUDIFY_FORCE` and `CLOUDIFY_CLEAR_DATA` before sourcing dependency recipes (subshell isolation)
- **D1:** Remote log filename matches local via `CLOUDIFY_LOG_BASENAME`; `ln -sf` creates `/tmp/cloudify/logs/latest.log` symlink after each run
- **A2:** Added `stdbuf -oL` before sed calls in SSH pipeline for line-buffered output
- **G1:** Removed redundant hermes config fixture from integration test; hermes-openwebui test reads auto-generated API key
- Files changed: `cloudify`, `lib/remote.sh`, `lib/package-api.sh`, `OPTIMIZATIONS.md`, `tests/unit/remote.bats`, `tests/unit/packages.bats`, `tests/integration/package-hermes-openwebui.bats`
- All 230 unit tests pass

## 2026-05-18 — Fix hermes gateway TEMPFAIL in integration tests

- Root cause: hermes installer writes 1100-line `config.yaml` with `provider: "auto"` (indented under `model:`).
  The auto-config check `grep -q "^provider:"` never matched the indented YAML, so KeylessAI was never configured.
  Gateway started with no valid API key, tried OpenRouter for 7-14 minutes, then TEMPFAILed.
- Fix: replaced the idempotency check to detect `provider:.*"auto"` pattern and overwrite with KeylessAI config
- File: `pkg/hermes/init.sh`
- All 12 hermes-openwebui integration tests pass

## 2026-05-15 — Shadow system hardening, test infra fixes, hermes auto-config

- Added explicit `/dev/null` stdin detection in shadow sudo (`[[ /dev/stdin -ef /dev/null ]]`)
  to skip `cat -` when stdin is /dev/null (after `exec </dev/null` in remote payload)
- Clarified `exec </dev/null` comment in `lib/remote.sh`: explains why closing stdin is
  needed and why pipelines within recipes still work
- Standardized test passwords: `testpwd` → `dummy` across all test files
- Standardized default admin emails: `admin@example.com` → `changeme@example.com` in READMEs
- Fixed open-webui: `docker compose up --force-recreate` in systemd service so env var
  changes take effect on restart (root cause 2 of env vars not applied)
- Moved `task lint` to run locally with auto-install of shellcheck (no container sync needed)
- Added rsync to `setup-container` task and `tests/run-integration.sh` snapshot provisioning
- Added SSH host key bypass flags to `ensure_snapshot()` in `run-integration.sh`
- Added prominent `--on` argument order note to usage text and CLAUDE.md
- Hermes package auto-configures KeylessAI as default LLM provider (free, no account, no API key).
  Only written if no provider already configured. Users run `hermes model` to switch to paid providers.
- Documented `CLOUDIFY_OPENWEBUI_BIND` in open-webui README for remote/container access
- All 222 unit tests pass, all 27 integration tests pass

## 2026-05-14 — Live remote logging + hermes-openwebui production deploy

- Added `exec >> file 2>&1 </dev/null` in payload template for live remote logging
- `</dev/null` closes stdin so shadow sudo's `cat -` gets EOF instead of blocking on SSH pipe
- Removed `tail -n +2` from local SSH pipe chain (was buffering all output until SSH closed)
- Fixed hermes installer clobbering Python entry point: hermes install.sh wrote bash wrapper
  to venv/bin/hermes via symlink, creating infinite exec loop. Restore correct Python entry
  point (`hermes_cli.main:main`) after installer runs.
- Added `--no-defaults` flag for minimal installs (basics + target only)
- Trimmed `basics` meta-pkg: removed mosh and silversearcher-ag; promoted silversearcher-ag to @default
- Fixed `pkg_depends` unbound variable: moved .script glob inside recipe branch
- Fixed mosh pkg stall: removed fragile `sudo tee` heredoc, made locale-gen idempotent
- Passed `WEBUI_ADMIN_EMAIL`, `WEBUI_ADMIN_PASSWORD`, `CLOUDIFY_OPENWEBUI_BIND` through remote payload
- Deployed hermes-openwebui on hermes prod: gateway healthy, open-webui on 0.0.0.0:3000,
  accessible via Tailscale at 100.106.4.58:3000

## 2026-05-13 — Diagnosed hermes-openwebui connectivity failure

- Ran full integration test suite (11/11 passing) for hermes-openwebui in container
- Both services healthy but Open WebUI shows no models in dropdown
- User confirmed: can login, sees connection URLs in Settings > Connections, but no models
- Read official docs (openwebui.com + hermes-agent.nousresearch.com) to correct mental model
- **Root cause confirmed**: Hermes API server binds to `127.0.0.1:8642` (default `API_SERVER_HOST`). Docker containers reach host via `172.17.0.1` (bridge gateway). Packets from bridge IP hit closed port.
  - `ss -tlnp` shows `LISTEN 127.0.0.1:8642`
  - `curl http://172.17.0.1:8642/health` → connection refused
  - `docker exec open-webui curl http://host.docker.internal:8642/health` → hangs 30s+
- Secondary issues: missing `ENABLE_OLLAMA_API=false`, `ENABLE_PERSISTENT_CONFIG=False` has known bugs
- Proposed fixes: `API_SERVER_HOST=0.0.0.0` in hermes env, `ENABLE_OLLAMA_API=false`, remove `ENABLE_PERSISTENT_CONFIG=False`
- Next: apply fixes to `pkg/hermes-openwebui/`, `pkg/open-webui/`, and update tests

## 2026-05-13 — Fixed hermes-openwebui (3 commits)

- Applied fixes to `pkg/hermes-openwebui/init.sh`: set `API_SERVER_HOST=0.0.0.0`, open UFW for Docker bridge
- Applied fixes to `pkg/open-webui/init.sh`: replaced `ENABLE_PERSISTENT_CONFIG=False` with `ENABLE_OLLAMA_API=False`
- Updated test fixture with `API_SERVER_HOST=0.0.0.0`, added tests for host value and Docker-to-hermes connectivity
- **Second blocker found**: UFW active with INPUT DROP policy blocks Docker bridge (172.17.0.1) even after hermes binds 0.0.0.0. Ubuntu 24.04 cloud image ships UFW enabled — not a cloudify package. Added UFW rule in hermes-openwebui init.sh
- 13/13 tests passing after all fixes
- End-to-end verified: openwebui -> hermes -> keylessai -> response. User confirmed "hello" -> "How can I help you"
- Also: added token efficiency + history sections to CLAUDE.md, fixed CLAUDE.md git remote docs (origin=GitHub, push with `git push`)
- Files changed: `CLAUDE.md`, `HISTORY.md` (new), `pkg/hermes-openwebui/init.sh`, `pkg/open-webui/init.sh`, `tests/integration/package-hermes-openwebui.bats`

## 2026-05-13 — Hardened hermes-openwebui for production use

- hermes-openwebui: gateway now installed as systemd user service (`hermes gateway install` + linger) instead of nohup
- open-webui: added `CLOUDIFY_OPENWEBUI_BIND` config (default `127.0.0.1`, set `0.0.0.0` for Tailscale access)
- open-webui: added `ENABLE_WEBSOCKET_SUPPORT=true` for mobile clients (Conduit)
- Test updated to use systemd service instead of nohup
- 13/13 tests passing, gateway confirmed running as systemd service with linger=yes
- Documented Docker-to-host networking in pkg READMEs
- Files: `pkg/hermes-openwebui/init.sh`, `pkg/open-webui/init.sh`, `tests/integration/package-hermes-openwebui.bats`, `pkg/hermes/README.md` (new), `pkg/hermes-openwebui/README.md`, `pkg/open-webui/README.md`

## 2026-06-05: lazygit — distro-version aware install

- Made lazygit recipe distro-version aware: uses `pkg_apt_install` on Debian 13+/Ubuntu 25.10+ where lazygit is in apt, falls back to GitHub release download for older distros
- Added idempotency guard (`command -v lazygit`) and `pkg_depends curl` for the GitHub path
- Kept existing `pkg_in_startuprc "alias lg=lazygit"`
- 3/3 integration tests passing on Ubuntu 24.04 container (GitHub release path)
- Files: `pkg/lazygit/init.sh`

## 2026-06-05: yazi — new package (terminal file manager)

- New package: `pkg/yazi/init.sh` — installs via `pkg_install_release` which picks the official `.deb` from GitHub releases
- Depends on `file` (prerequisite per yazi docs)
- Adds `alias y=yazi` to .bashrc
- Verified working on Ubuntu 22.04 (local install)
- Bug: glibc .deb requires 2.39+ — Ubuntu 22.04 has 2.35 → switched to musl .deb on older distros
- Bug: arch conversion x86_64→amd64 broke URL — yazi uses x86_64/aarch64 in filenames → use uname -m as-is
- Integration test written but not yet run (incus remote unreachable)
- Files: `pkg/yazi/init.sh`, `tests/integration/package-yazi.bats`

## 2026-06-11: hermes-dashboard — persistent web dashboard via systemd + tailscale serve

- New package: `pkg/hermes-dashboard/` — runs hermes dashboard as a systemd user service
- Includes `relay.py` — aiohttp reverse proxy that rewrites Host header for tailscale serve compatibility (workaround for missing --allowed-hosts, hermes-agent#34390)
- Exposed via `ivps expose-direct cloudai:hermes 9120 --path /dashboard` → https://hermes.komodo-everest.ts.net/dashboard
- Added PATH to systemd unit (node/npm at ~/.local/bin needed for web UI build)
- Added dashboard readiness check in relay (waits up to 30s for first-launch web UI build)
- Verified: systemd service active, relay HTTP 200, tailscale HTTPS 200
- Roadblock: path-based routing (`--path /dashboard`) breaks SPA — JS bundles use absolute `/api/*`, `/fonts/*` paths
- Root exposure works (`https://hermes.komodo-everest.ts.net/`) but collides with Open WebUI on same container
- Solution: ivps needs `expose-private-hostname` command for hostname-based tailnet routing
- See `/home/rbc/.pi/handoffs/2026-06-11-ivps-expose-private-hostname.md`
- Files: `pkg/hermes-dashboard/init.sh`, `pkg/hermes-dashboard/relay.py`, `tests/integration/package-hermes-dashboard.bats`

## 2026-06-11 — expose-private-hostname rejected; separate containers chosen

- Investigated ivps `expose-private-hostname` for tailnet hostname routing via Caddy on gateway.
  Found fatal TLS flaw: Tailscale CA doesn't issue subdomain certs (`dashboard.hermes.ts.net`).
  Issue [#7081](https://github.com/tailscale/tailscale/issues/7081) still open.
- Evaluated alternatives: Tailscale Services (requires tagged identity + admin console setup),
  DNS-01 + Let's Encrypt (requires Caddy rebuild), separate containers.
- **Decision: separate containers.** Hermes dashboard stays on hermes container at root
  (`tailscale serve --bg 9119`). Open WebUI moves to its own container with its own
  MagicDNS hostname. Each gets root HTTPS + auto-TLS with zero infra changes.
- See `/home/rbc/.pi/handoffs/2026-06-11-cloudify-separate-containers.md`

## 2026-06-11 — Architecture refined: SSH tunnel for dashboard, MagicDNS for API

- Common-sense tested all assumptions from previous handoff via exa research.
  Confirmed: subdomain certs dead (#7081), SPA path routing broken (#12413),
  Tailscale Services require tags+approval, caddy-tailscale only issues certs
  for local machine.
- Key correction: hyphens in machine names (`openwebui-hermes`) are NOT subdomains.
  Tailscale MagicDNS and CA treat hyphenated names as first-class machine identities.
  `openwebui-hermes.komodo-everest.ts.net` gets a valid cert.
- Rejected Caddy as central reverse proxy: one Caddy on cloudai can't serve
  multiple MagicDNS hostnames because caddy-tailscale only gets certs for its
  own machine's FQDN. Central Caddy only works with path-based routing → SPAs break.
- **Final architecture:**
  - `hermes` container: tailscale serve (:443 → agent :8642), dashboard loopback-only via SSH tunnel (`ssh -L 9119:127.0.0.1:9119 hermes`). No relay.py. No dashboard tailscale serve.
  - `openwebui-hermes` container: tailscale serve (:443 → Docker :3000), Docker DNS 100.100.100.100 for MagicDNS, `OPENAI_API_BASE_URL=https://hermes.komodo-everest.ts.net/v1`
  - No Caddy. No hardcoded Tailscale IPs. No path-based routing anywhere.
- Cloudify changes:
  1. `hermes-dashboard/init.sh` — simplify: direct dashboard (:9119 loopback), remove relay.py, post-install shows SSH tunnel command
  2. `open-webui/init.sh` — add `dns: 100.100.100.100` to docker-compose, support remote hermes URL from credentials
  3. `hermes-openwebui/init.sh` — remove same-machine assumptions, support remote hermes via MagicDNS
  4. New `hermes-openwebui/connect-remote.sh` — wire open-webui to hermes across Tailscale
  5. Tests for all of the above

## 2026-06-11 — separate-containers v2: deployment in progress

- **Merged PR #1**: hermes-dashboard (no relay, SSH tunnel), open-webui (MagicDNS dns), hermes-openwebui (remote via MagicDNS). 9 files changed, +362/-439.
- **Merged** 388e79d: remote.sh now passes CLOUDIFY_HERMES_API_URL and CLOUDIFY_HERMES_API_KEY through remote payload
- **hermes container** (cloudai:hermes): stopped open-webui Docker, removed relay.py, dashboard running standalone on 127.0.0.1:9119 (ssh -L tunnel), tailscale serve reconfigured to serve API at root `/` → 8642. Gateway + Slack still running.
- **TS_AUTH_KEY** was expired (one-off key from April). User generated new reusable key with tag:incus. Required ACL rule `tag:incus → tag:incus:443` added.
- **openwebui-hermes container** (cloudai:): created via `ivps launch`, Tailscale connected with tag:incus, MagicDNS resolving hermes hostname. SSH set up. Credentials configured.
- **open-webui installed** via cloudify. Docker container starts but crashes with `ValueError: No embedding model is loaded`. Patched compose with `RAG_EMBEDDING_ENGINE=` to disable embeddings. Still not healthy — container keeps restarting.
- **Roadblock**: open-webui won't stay up. Needs debugging — may need different RAG_EMBEDDING_ENGINE value or additional env vars.
- **Untested**: hermes-openwebui package install (credentials passthrough fixed but open-webui must be healthy first), tailscale serve on openwebui-hermes, end-to-end TLS verification.
- **pkg/piface added** (commit f822518, master). Recipe installs piface (web UI for the pi coding agent) as a systemd user service on 0.0.0.0:7832. Stack: node(mise)+pi(npm `@mariozechner/pi-coding-agent`), uv(standalone)+piface(PyPI wheel bundles built frontend, no node/pnpm build), ffmpeg(apt). Deployed on `cloudai:piface` container.
- **Exposure decision**: used `tailscale serve --bg --https 443` on the container (→ `https://piface.komodo-everest.ts.net`) instead of a VIP Service. Reason: the container is itself a tailnet node named `piface`, so `svc:piface` collides with the node name (Tailscale 400 "name exists but is not a service"); the node's own name gives the nicest URL with zero admin-approval step and tailnet-only HTTPS (secure context for browser mic). VIP Services remain the pattern for multi-component/production stacks (cf. hermes).

## 2026-08-06 — pending decisions/actions ledger (so nothing is forgotten)

- **⛔ GOVERNANCE GATE (persisted in CLAUDE.md, top of file)**: cloudify's env-var forwarding (`lib/remote.sh`) and shadow functions (`lib/shadows/*.sh`) are extremely brittle bash magic. No code change to cloudify without: (1) a subagent whose unique mission is to describe that bash magic, (2) an implementation plan arguing why it can't break the mechanisms, (3) explicit human consent.
- Finish the k3s e2e and prove it works (recipes + e2e spec on feat/k3s-recipes; blocked on the ivps F1 operator-grant fix).
- ivps F1 operator-grant fix (operator is tag:workstation, not autogroup:member; all 15 tailnet devices tagged) — prompt handed to main agent for the ivps coding agent; its merge unblocks the e2e + the launch SSH-ready wait.
- Recipe-dance story: skill now, roadmap a `cloudify recipe` subcommand (exact shape undecided).
- Standing rule: all future cloudify changes stay additive + default-off; pkg-shape backward compat is regression-tested (init.sh-only pkgs byte-identical).
- Cluster tags use `cluster-<name>`, not `k3s-<name>`.
- Build out ADR-011: deployment-wide store + `cloudify vars set/delete/list` + `CLOUDIFY_DEPLOYMENT` context (unblocked) ; per-node slices (blocked on ivps PR #14); `cloudify deployment list/delete`.
- Debug payload masking must cover TOKEN/KEY (K3S_TOKEN currently unmasked); `vars set --stdin/--file` for secrets.
- Merge queue: cloudify #9/#10, ivps #12/#13/#14 (all open). C3 issue #7 acceptance to be updated to ADR-011 shape.
- ADR-010 operator-reach wording correction when the ivps fix lands. Secrets security model study (Secrets V2) tracked. `clone deployment` optional follow-on.

## 2026-08-06 — ivps boundary decisions (from PR/UX review)

- **Separation (human decision):** `ivps tag create/delete` = identity only (tagOwners + join key). Network linking moves to the new `ivps acl grant/revoke`; the cluster recipe does the linking with an explicit operator set (tag:workstation, tag:mobile) — never hardcoded autogroup:member. This dissolves the F1 operator-grant bug by design; the e2e now waits on `ivps acl` existing, and the cloudify recipes get a small update to call it.
- **Lock (human decision):** ivps must hold an exclusive lock around every ACL write + 412-retry must re-derive from a fresh fetch (spec's no-locking assumption rejected).
- **F3 (human decision):** `feat/node-path` merges (per-instance state surface for deployment slices). Note: after merge, the stranded nested `nodes/cloudai/` is the correct layout — re-adopt and cull the flat orphan instead of the spec's original direction.
- Prompt handed to the main agent for the ivps coding agent (merge order #12→#13→#14 with the separation change; implement `ivps acl`; concurrency + operator-reachability acceptance).

## 2026-08-07 — ivps Phase 1 complete; k3s e2e unblocked

- **ivps Phase 1 done** (main: aa11968): all 4 PRs merged — F1 tag create/delete/list (#12, 1449402), F2 launch --tag (#13, a4f48d9), F3 node-as-dir + node path (#14, f2ce76c), ACL surface grant/revoke/rollback/show (#15, 874f9ac). ACL writes locked (exclusive flock), snapshotted (keep 10), 412-retry re-derives from fresh fetch. Live e2e green. Separation (identity/policy) per 2026-08-06 boundary decisions.
- **k3s e2e updated for ivps acl** (feat/k3s-recipes): First test now calls `ivps acl grant` for mesh (tag:self --port 6443,8472) + operator (tag:workstation,mobile --ssh) after `ivps tag create` and before `ivps launch --tag`. Teardown order fixed: delete nodes → acl revoke → tag delete. PLAN.md updated — Phase 1 ticked complete.
- **Merge queue:** cloudify #9/#10 still open. ivps #12-#15 merged to main.
- **Next:** C3 deployments (ADR-011) — needs CRITICAL GATE: subagent description of bash magic → implementation plan → human consent. Also: stack feat/k3s-recipes onto master (C1+C2 PRs first, then rebase k3s branch).

## 2026-08-09 — k3s e2e manually validated green (7/7 steps); rotation deferred

- **Manual validation of every e2e step** (user-directed: one test at a time, not batch): tag+acl grant → launch (SSH-ready) → WSL SSH + MagicDNS → code push → k3s-server install + Ready at tailscale IP → k3s-agent joins → k3s-cli (kubectl context + helm) → isolation (prod↔dev 6443 blocked). All green.
- **Fixes made en route:**
  - k3s-cli helm: get-helm-3 ALWAYS copies via runAsRoot (sudo) when not root — HELM_INSTALL_DIR alone doesn't avoid it. Fix: `USE_SUDO=false` + process substitution (env var on a pipeline only reaches the first command). Verified helm v3.21.3 → ~/.local/bin, no sudo.
  - e2e install assertions: SSH pipe can drop mid-install on WSL2 (remote work continues detached, cluster still comes up — cloudify reports FAILED as a false negative). Install steps now WARN on non-zero exit; the readiness poll is the real gate.
  - e2e launch: sequential (parallel raced tailscale device registration, intermittent SSH timeouts on nodes 2-4); tokens written to `$WD/tokens.env` in setup_file + sourced in setup (bats @test runs in subshells, setup_file exports lost); setup_file deletes ALL stale k3s-* tailscale devices from interrupted runs (DNS collision → `-1`/`-2` suffixes broke MagicDNS); verify via `incus list` (ivps list doesn't show tagged nodes).
- **Token rotation DEFERRED (user decision, ROADMAP'd)**: rotating a running single-server k3s join token is a k3s limitation — the token IS the etcd bootstrap encryption key; changing it fatal-fails on restart ("encrypted with different token"). Test 8 dropped from e2e; the broken token-overwrite block removed from k3s-server/configure.sh (it killed any cluster whose K3S_TOKEN differed on re-configure). Validate `cloudify configure` run-phase on a simpler split pkg later. See ROADMAP "cloudify configure re-run validation".
- **Open questions:** run the full bats e2e once as final green, or merge on the strength of manual validation? feat/k3s-recipes is ready either way (C1+C2+k3s recipes+e2e, pushed).
- **State:** feat/k3s-recipes (this branch) holds C1+C2+k3s recipes+e2e+docs; no PR yet. Deployments work (deployment-wide store + cloudify vars) sits on feat/deployments (based on master, 23 unit tests green, unpushed review). ivps main aa11968 (F1+F2+F3+ACL merged).

## 2026-08-10 — k3s validated by real helm deploy (ntfy); k3s-cli merge bug fixed

- **Full-stack cluster proof via a real helm chart**: re-spun the prod cluster (same 7 manual steps), deployed **ntfy** (official chart, oci://codeberg.org/wrenix/helm-charts/ntfy), exposed via `tailscale serve` on the node → **https://k3s-prod-1.komodo-everest.ts.net/** with a real Let's Encrypt cert.
- **Verified end-to-end**: pod scheduled+Running, NodePort service routing, web UI served, API publish → read-back round-trip, and **sqlite persistence through pod kill+reschedule** (cache.db on a local-path PVC).
- **Chart gotchas learned**: ntfy chart cache value path is `ntfy.cache.file` (not `cache.file`); PVC mounts at `/data` (not the commented /var/www/html); k3s ships local-path StorageClass so PVCs provision out of the box.
- **k3s-cli kubeconfig merge bug found + fixed (cd503c9)**: k3s writes cluster/user/context all as "default"; recipe renamed only the context, so merging a 2nd cluster left both contexts pointing at one "default" entry (multi-cluster silently broken) and re-deploys kept stale CAs (kubectl: unknown authority). Now uniformly renames context/cluster/user to $K3S_CONTEXT, merges KCFILE-first. Verified live.
- **Chosen chart rationale**: ntfy = lightest (Go, ~30MB), official chart, REST API + web UI, sqlite, zero external deps (round-trip with self-created data; Miniflux rejected — needs external RSS feeds to verify).
- **State:** feat/k3s-recipes ready to merge (recipes + hardened e2e + all fixes).

## 2026-08-10 — k3s track merged to master (one merge at a time, sanity after each)

- **Merge 1**: feat/remote-vars → master (169ca41, PR #9 auto-detected MERGED). Sanity: lint + 276/276 unit tests in container.
- **Merge 2**: feat/install-run-split → master (114b5e1, PR #10 auto-detected MERGED). README conflict (piface docs vs .remote-vars line) resolved by keeping both. Sanity: 283/283.
- **Merge 3**: feat/k3s-recipes → master (d38ba17). HISTORY conflict (master's piface entries vs branch's 08-06..08-10 ledger) resolved chronologically, both kept. Sanity: 289/289 (k3s structural tests now in suite), lint clean.
- **Full chain on master now**: pkg .remote-vars + install/run split + k3s-server/agent/cli recipes + live multi-cluster e2e spec (e2e itself is a live-tailnet test, run manually — last full manual validation 2026-08-09, 7/7 steps green).
- **Open threads**: feat/deployments (deployment-wide store + cloudify vars, 23 unit tests green) parked on master base; not part of this merge. Feature branches feat/remote-vars, feat/install-run-split, feat/k3s-recipes can be deleted.

## 2026-08-10 — pkg/affine (staged-deployment track)

- **New package**: `pkg/affine` — deploys the clean-room Linear MCP server
  (rachidbch/affine, private repo, cloned via the git shadow's GitHub creds).
  Node LTS via mise, `npm ci`, systemd user service on :8787.
- **Master-token bootstrapping**: first boot mints the master identity
  (role 'master', ADR-019 model); the recipe prints the token so the operator
  mints the first admin (`create_user role=admin`) and stores the master
  offline. `--clear-data` re-mints (old token dies).
- **Verify**: service active + unauthenticated POST /mcp answers 401.
- Integration test: tests/integration/package-affine.bats.

## 2026-08-10 — pkg/affine integration-test fix

- **Root cause (shadow)**: the cloudify git shadow compares options with a
  literal `"!= \"-*\""` (quoted, not a glob), so `git clone --depth=1 URL`
  fed `--depth=1` to the URL parser and rejected it ("Not a valid git url").
  Fix: no options on the clone (plain `clone URL PATH`), which the shadow
  parses cleanly. Integration test now 5/5 green.
- **Root cause (creds)**: the stored cloudify GitHub credential was a
  14-char password (not a PAT — GitHub killed password auth in 2021), so
  private clones 401'd. This is the first pkg to clone a private GitHub
  repo. The laptop's gh OAuth token was used for the test; the durable
  credential update is the human's call (see OPEN THREADS).
- **Live verification (staged)**: installed on the cloudify container;
  master token printed; 7/7 probes green (master identity, mints admin,
  admin-mint denial pinned string, master undeletable/undemotable, recovery
  mint).

## 2026-08-10 — feat/deployments battery GREEN (integration suite 32/34)

- Full battery: lint clean, unit 297/297 (289 + 5 git-shadow + 3 credentials),
  integration 32/34. Failures = exactly {hermes-dashboard, hermes-openwebui} —
  both OUT OF SCOPE (user decision 2026-08-10). Zero new failures.
- All 3 in-scope defects fixed + verified one-by-one: affine 5/5 (git shadow
  clone-arg parser + CLOUDIFY_GITHUB_READONLY_TOKEN end-to-end), hunk 3/3
  (private npm prefix /opt/hunkdiff + symlinks), yazi 3/3 (pkg_depends unzip +
  fail-fast die). Recipe fail-fast systemic fix parked as issue #14 + ROADMAP.
- Skill: LEAN "Credentials & secrets" section added (filesystem-only, no commit).

## 2026-08-10 — deployments live validation PASSED (token from store, not env)

- Built a 2-node k3s cluster with the join token coming ONLY from the deployment
  store: `cloudify deployment create k3s-live-test` + `vars set K3S_TOKEN <t>` →
  `CLOUDIFY_DEPLOYMENT=k3s-live-test cloudify --on <server> install k3s-server`
  (no env token) → server config.yaml carried the store token → agent joined →
  2 nodes Ready. Proves ADR-011 end-to-end + the §5.1 payload fix live.
- Infra incidents fixed along the way: (1) incusd on cloudai lost its network
  listener (core.https_address hostname DNS-race after a daemon restart) —
  pinned to 100.87.49.111:8443, live re-bind, no restart needed; (2) the Windows
  workstation had LOST tag:workstation (grant matched nobody — the F1 bug in
  reverse); user retagged it via the admin console → k3s nodes instantly
  reachable. Investigation: ivps source has NO device-tag write path, and the
  API rejects removing in-use tagOwners — so ivps cannot have stripped the tag;
  cause of that loss remains unexplained (admin audit log if it recurs).

## 2026-08-30 — handoff: dsh lifecycle implementation closed

- **Closed**: dsh lifecycle split is committed and pushed (`eb11c9e`); all 305 unit tests and shellcheck pass in `cloudai:cloudify`; production dsh was not touched. No active blocker remains. Future production updates use `cloudify --on <node> configure deepseek-harness`, never `--clear-data` for routine updates.

## 2026-08-31 — Omarchy VM automation preflight (ADR-015)

- Official Omarchy research confirmed ISO-only installation with unattended `cidata` configuration; no VM was created after a mistaken local ISO download was aborted and trashed; next execution downloads directly on cloudstation and creates an Incus VM before automating Guacamole.

## 2026-08-31 — Omarchy deployment deferred (ADR-016)

- Root-caused the cloudstation SSH blocker: `/etc/hosts` pinned `cloudstation` to its public IP (45.151.123.90), bypassing MagicDNS — every admin action went over the internet as root. User removed the pin; `ssh cloudstation` now reaches the tailnet (Tailscale MagicSSH), so the oracle's management plane is tailnet-only from now on.
- Re-grounded the plan with web research: Omarchy = Arch + Hyprland (Wayland) + Quickshell; v4.0.1 ISO + SHA256 confirmed; xrdp cannot serve Wayland (maintainer-confirmed, xrdp#2637), the community remote-desktop path is wayvnc/VNC; no precedent exists for Omarchy's full desktop in an LXC/Incus container (domarchy wraps QEMU, devmarchy is CLI-only).
- Decision: no Incus VM (QEMU overhead unacceptable on cloudstation's 8 GiB/4-core host) and no container experiment until the community proves one. Omarchy automation parked; ADR-015 superseded by ADR-016.
- `ivps tag create incus` minted the `tag:incus` authkey (cache `~/.config/ivps/tags/incus.env`, reusable, expires 2026-09-01 02:05) ready for the eventual headless join.

## 2026-08-31 — Guacamole admin password reset (lost credentials)

- Reset the web-admin (`rbc`) password in `guacamole_db` with the SOP salt+hash formula; discovered Guacamole 1.6.0 moved the login name to `guacamole_entity.name` (no `username` column on `guacamole_user`). Login verified via `/api/tokens`. New password stored in `/home/rbc/guacamole/.env` (600), never in the repo.

## 2026-08-31 — guac-gui auto-tiling; XFCE theming parked (upstream xrdp bug)

- Enabled Cortile auto-tiling (v2.5.2, checksum-verified) + autostart on guac-gui; windows tile automatically. Wallpaper set to user image. New snapshot `guac-gui-cortile`.
- Investigated XFCE theming under xrdp; root-caused to a known upstream bug (xorgxrdp lacks XI2 → xfsettingsd can't register `_XSETTINGS_S0` → no GTK theme), confirmed by Launchpad #354830 + Xfce forums. Parked — cosmetic, low-ROI to fix; delivered tiling/speed/wallpaper instead.

## 2026-08-31 — "Restore this snapshot" nag on guac-gui (incus-agent false positive)

- **What**: guac-gui shows a persistent "You are currently using this snapshot. Please restore it before rebooting to the normal system." banner.
- **Why**: a false positive from the guest's incus-agent. The container was frozen during `incus snapshot create` (guac-gui-cortile) while running; the agent misreads the freeze/thaw as "booted from snapshot." Verified NOT running from a snapshot: `incus info` shows the original boot (Created/Started same-time), no restore/snapshot source.
- **To remove**: reboot the container clears it (agent reset); it may recur while snapshots exist. Permanent fix = delete the guac-gui snapshots (`guac-gui-pre-cortile`, `guac-gui-cortile`) — but those are the rollback points, so keep them unless the nag is intolerable. Harmless either way.

## 2026-09-07 — guac-gui + Guacamole end state re-verified (read-only)

- Re-verified the oracle read-only: Guacamole stack Up 7 days (1.6.0/guacd/postgres 16, bind 100.102.121.73:8080).
guac-gui RUNNING (.12, xrdp 3389); gui in sudo group; Cortile autostart present.
Tailnet name back to plain `guac-gui`; both snapshots intact.
- SOP draft corrected (stale `guac-gui-1` reference, duplicate-hostname gotcha).
- Journal 2026-09-07 holds the reconnect notes (connection name, credential pointers, gotchas).

## 2026-09-07 — pkg/guacamole shipped; pkg_depends scope leak fixed

- **pkg/guacamole built + green**: split pkg (install.sh + configure.sh + verify.sh + .remote-vars), Apache Guacamole 1.6.0 + guacd + postgres 16 compose stack, DB init via docker cp + psql -f (no stdin through sudo), admin with the SOP hash formula, RDP connection upsert via REST API. Integration 5/5 bats on cloudai:cloudify.
- **Core bug fixed (CRITICAL GATE, consented)**: `pkg_depends` looped `for pkg in "$@"` without `local pkg`, leaking into `_cloudify_source_pkg_phases`' dynamically-scoped `pkg` — any split pkg whose install.sh pulls a dep silently skipped configure.sh on install (guacamole was the first such pkg; latent since ADR-008). One-line fix + regression fixture pkg/fixture-dep-split.
- **Oracle config facts learned**: guacamole image needs `WEBAPP_CONTEXT: ROOT` (else serves at /guacamole and every / -based check fails) and reads `POSTGRESQL_*` env (not POSTGRES_*). Both were in /home/rbc/guacamole/compose.yaml on cloudstation; the SOP prose did not carry them.
- **itest-base refreshed**: recreated with a valid tailnet identity (snapshot restores time-travel tailscale state; the old snapshot's identity was rejected → container off the tailnet, NeedsLogin) + the three docker images baked (run dropped from ~15 min to ~1 min).
- **Test observability**: guacamole bats streams install progress with stall detection (no silent e2e); cloudify skill gained "Debugging a recipe" (probe ladder, no-silent-steps, logging prominence).

## 2026-09-07 — change A (errexit restore) rejected by gate; verify heartbeat landed

- **Gate run (description artifact plans/errexit-restore-description.md)**: proposal to restore real errexit in recipes by restructuring pkg_depends' `if ! ( ... )` wrapper was REFUTED. Grounds: (j-1) rc bookkeeping unreachable in active paths (errexit kills the process before `_rc=$?`); summary/continue semantics lost; (j-2) @default path stays masked (router `if ! cloudify_install_package $defaults`, not pierceable by nested set -e); (j-4) ERR-trap cleanup would rm -rf shared temp mid-recipe; audit found ~150 genuine unguarded failure-prone commands across 84/97 recipes that would false-abort working installs. Decision: no framework errexit change; silent-continuation is handled by recipe discipline (explicit `|| die` + postconditions, already house style, applied to guacamole/xfce).
- **Verify heartbeat landed (bfa1016)**: `_cloudify_run_verify` logs attempt progress every ~20s during retries; silent verify black box eliminated. Regression assert in package-install-run-split.bats.

## 2026-09-07 — pkg/xfce shipped; full E2E acceptance passed

- **pkg/xfce shipped (split, ADR-008)**: XFCE + xrdp GUI endpoint; password model per ADR-017 (env-passed preserved, auto-generate+print fallback); chrome via DEB822 repo with dearmored keyring (oracle facts); explicit `|| die` + postconditions everywhere (errexit suspended in recipes, ADR-018). Integration 5/5 bats (package-xfce.bats) on cloudai:cloudify.
- **E2E acceptance passed (ADR-019)**: disposable stack - cloudai:xfce-test guest (100.64.249.76) + guacamole on cloudai:cloudify (100.123.125.109), wired via deployment xfce-gui (single source). Human browser session confirmed XFCE render over guacd->xrdp through the tailnet. Production oracle untouched.
- **Root cause found (cleanup-order bug)**: deleting /root/guacamole BEFORE `docker compose down -v` silently orphaned the stack's postgres volume into itest-base; the later install recreated the container with a new DB password but the volume kept the old role password -> webapp DB auth failed. Fixed via pkg-native `--clear-data`; lesson: compose down before removing the project dir.
- **Process**: cloudify skill hardened through the session (Logging section, L0-L4 ladder, errexit-suspension contract, exit-marker polling pattern). Env findings: stale snapshot tailnet identity (re-auth + re-bake), itest-base invariant = no codebase, no leftover stacks, valid identity, images baked.

## 2026-09-07 — surface-cleanup design session (traps, vars, secrets, runbooks)

- **Traps reviewed 1-7** (originally 8; 2+3 collapsed after reading lib/remote.sh refuted my claims - only the env path is declaration-gated, file stores forward unconditionally). All resolutions recorded in ROADMAP "URGENT".
- **Vars**: flag-scoped CLI (`--global|--pkg|--deployment`); pkg-writing standard `NAME` / `NAME=value` / `NAME=` (declaration = documentation mirror; recipe `${VAR:-}` stays runtime truth); `vars declared <pkg>` reader showing the three kinds; five-source read/write helpers + precedence walker (target: recipe default < global < package < deployment < env; today global strongest and deployment weakest); resolver seam (identity default, `@backend:locator`, `lib/secrets/*.sh` plugins) with two vault models (operator-side default, host-side) and the exposure inventory (stdin-payload hardening).
- **Lifecycle**: install provisions / configure configures / uninstall tears down (extends ADR-008); compose-semantics-first (`up -d --wait`, healthchecks) over bash loops; guacamole becomes the reference 3-leg rewrite; guacamole admin default `rbc` -> `guacadmin`.
- **State**: registry slices keyed (deployment, instance, package), a REPLAY input outside the precedence ladder; supersedes ADR-011 point 6 (amend when implementing). Names not IPs (MagicDNS); address-shaped values derived at run time.
- **Runbooks**: (a) agent runbooks under `runbooks/` with an amnesiac validation protocol; (b) `cloudify deployment run` on the fixed surface; idea 3 (declarative generator) parked non-urgent.
- **Plan**: plans/urgent-surface-cleanup.md (8 branches, merge before next), PLAN.md repointed.
- **Skill**: Logging section, L0-L4 testing/debugging ladder, errexit-suspension contract, run hygiene (exit-marker polling, raw reads, PID kills). Security section pending (branch 3).

## 2026-09-09 — branch 1 gate description; single-file URGENT plan

- **Gate description done (read-only subagent, no code touched)**: current var forwarding + precedence traced end to end (`lib/remote.sh:98-230`, `lib/deployments.sh:178-196`, `lib/pkg-config.sh:19-45`), 30 empirical repros in `~/tmp/vars-desc/e*.sh` (E1-E16). Artifact absorbed into `plans/urgent-surface-cleanup.md`; the standalone artifact file was trashed (Rachid mandate: all planning/progress in that one file).
- **5 claims corrected**: `remote-vars.yaml` is loaded by `_cloudify_load_yaml_vars` (pkg-config.sh:19 via remote.sh:152), not `credentials.sh`; `.remote-vars` today accepts bare `NAME` only (`NAME=value`/`NAME=` silently skipped, remote.sh:139); caller env is NOT strongest today (global file beats it, E1c; per-pkg yaml beats it for undeclared names, E14); remote.sh:128 "env wins" comment half false; README:159 single-source-of-truth is remote-only. Confirmed: global strongest / deployment weakest; only the env path is declaration-gated.
- **Two live hazards found**: `xargs` in `_cloudify_deployment_read_vars` (deployments.sh:187-188) mangles `'`/`\`/spaces and aborts on multi-line values (host FAILED); no reserved-name guard, so a config key `CLOUDIFY_REMOTE_USER` retargets ssh (E16).
- **Plan restructured** (`plans/urgent-surface-cleanup.md`): single tracking file for ALL URGENT work, every task marked `[ ]`/`[~]`/`[x]`/`[v]`; added Branch 1b (vars CLI + declaration syntax + `vars declared`, previously unassigned); inlined invariants I1-I12, landmines L1-L12, proposed resolutions R1-R9, trap->branch map.
- **State**: Branch 1 gate = description `[x]`, plan `[~]`, consent `[ ]`. No lib/router/test change.

## 2026-09-09 — branch 1 landed: vars internals (five-source helpers + walker + resolver)

- **Implemented (gate consent recorded)**: `lib/vars.sh` (five-source read/write helpers, claim ledger, non-clobbering reads, reserved-name deny-list R5, secret resolver R4), `lib/secrets.sh` + `lib/secrets/base64.sh`, walker rewrite in `lib/remote.sh` (strongest-first: env > deployment > package > global, target `default < global < package < deployment < env`), local-path walker in the router (R1), canonical `cloudify_vars_deployment_*` + legacy aliases (R7), deployment reader pure-bash trim (R6, no `xargs`), 0700/0600 on both yaml store writes (I10).
- **Tests**: new `tests/unit/vars.bats` (40 tests: helpers, resolver, reserved guard, R6 special chars/multi-line, precedence matrix, R1 local install path); full unit suite 345 green in `cloudai:cloudify`; pinned `remote-vars.bats` / `deployments.bats` / `package-api.bats` / `remote.bats` / `install-run-split.bats` green unmodified; both pinned integration files (`package-remote-vars`, `package-install-run-split`) green.
- **Write-side L4 closed in review**: `_cloudify_vars_file_set` stored multi-line values raw and silently truncated them at the first newline; now stored as `@base64:` (R6) with a round-trip test.
- **Latent bug fixed**: dep scan `deps=$(grep ... | sed | tr)` returned 1 for a recipe with no `pkg_depends` line and aborted the walk under errexit+pipefail; present in pre-branch code, fixed with `|| true` and proved by the local-path test.
- **Plan-internal contradiction resolved**: I5/L9 (deployment must not clobber earlier claims) conflicts with the target precedence repeated in task 3 + ROADMAP M1-M4 (deployment > package). Implemented deployment > package; I5 honoured for the caller env only. No pinned test asserts either order; flagged for the ADR trail.
- **R4 refinement**: resolver called from file-store readers and the verify yaml load, not the env reader — with R1 the host re-runs the walker, and re-resolving the already-plaintext payload env would break the `@@` escape across the SSH hop.
- **Docs**: README var sections corrected (five sources + precedence + secret references + reserved names).
- **Merged** to master (`397c064`, --no-ff) after the e2e merge gate: unit 345/345, `package-remote-vars` + `package-install-run-split` PASSED. AGENTS.md/CLAUDE.md Configuration bullet corrected (consent; AGENTS.md is a symlink to CLAUDE.md).

### 2026-09-09 - branch 1b gate: description + plan

- Read-only description of the vars CLI surface (router `cloudify:491-563`, declaration parser `lib/vars.sh:197-222`, write path, pinned tests); repros `~/tmp/b1b/`. Found: router arg parsing has NO test (`shell-router.bats` empty on vars/deployment); declaration accepts bare `NAME` only; `vars set V --global` today stores `--global` as the value; write allows lowercase keys their own reader ignores.
- Plan + non-breakage argument written into `plans/urgent-surface-cleanup.md` (Branch 1b): invariants I1b1-I1b8, landmines L1b1-L1b10, resolutions R1b-1..R1b-11, tasks T1-T8, tests, merge gate. Consent pending.

### 2026-09-09 - branch 1b: vars CLI surface + declaration syntax + `vars declared`

- **Landed**: declaration kinds `NAME`/`NAME=value`/`NAME=` (mirror only, never a value source; warn only for required), declared-file kind column, scope flags `--global|--pkg|--deployment` with `--` sentinel and mutual exclusion, `unset` alias, optional deployment id arg, write-time `@` reference validation (option A: backend must exist), uppercase key guard for global/pkg, byte-preserving `--stdin`/`--file`, `vars declared [--sources]` with `PASSWORD|TOKEN|SECRET|KEY` masking, pure-bash `--json` escaping, `show` missing key exits 0.
- **Tests**: new `tests/unit/vars-cli.bats` (22); full unit suite 367 green; shellcheck clean; router-subprocess coverage closes the shell-router vars gap.
- **Merge gate green**: `package-remote-vars.bats` PASSED; CLI smoke on `cloudai:cloudify` (`vars declared guacamole --sources`, scoped set/show/list, stdin secret, `@` reject).
- **Deviation (approved R1b-7)**: unknown backend now dies at write time, so the branch-1 test "walker: an unresolvable file-store reference dies" writes the file directly to keep proving the read-time die; `deployments.bats`/`remote-vars.bats` untouched.
- **Open**: R9 (default masking on `vars show`/`list`) contradicts pinned exact-value tests; opt-in `--mask` proposed, consent pending.

### 2026-09-09 - R9 resolved: printing secrets is opt-in (branch 1b-fix)

- Rachid decision: printing a secret is always an explicit opt-in. `cloudify vars show`/`list` now mask values whose name matches `PASSWORD|TOKEN|SECRET|KEY` by default; `--reveal` prints them; `--resolve` decodes a `@backend:locator` reference (still masked unless `--reveal`); `vars declared --reveal` unmasks a defaulted mirror.
- Masking lives in the router only: the library functions (`cloudify_vars_show/list`, store helpers) stay raw, so the pinned exact-value tests (`deployments.bats:108-126`, `:167-184`) hold unchanged.
- Tests: 5 new router tests; full unit 372 green; shellcheck clean; CLI smoke on `cloudai:cloudify` shows `***` by default, `tok` with `--reveal`, `s3cr3t` with `--resolve --reveal`.

### 2026-09-09 - branch 2 gate: verify + uninstall description + plan

- Read-only description of the action surface (parser tables `cloudify:180-203`, `--on` host swallowing `verify` into `No packages found`, dispatch, phase sourcing, verify paths, dep walk); repros `~/tmp/b2/`. Found: `remove|rem|r` documented but unimplemented; empty-package guard omits `--uninstall`/`--verify`; local uninstall skips the walker; a pre-existing verify-yaml clobber (walker value overwritten).
- Alignment confirmed with Rachid: absent `uninstall.sh` = clear error, no action, non-zero; deps never auto-removed (consent-gated). Non-urgent ROADMAP entry added: "Dependency garbage collection".
- Plan + non-breakage written into the plan file (invariants I2-1..I2-12, landmines L2-1..L2-12, resolutions R2-1..R2-12). Gate widened to `lib/remote.sh`. Consent pending.

### 2026-09-09 - branch 2: verify first-class + real uninstall

- **verify action**: `cloudify verify <pkg>` and `cloudify --on <host> verify <pkg>` both work; the top-level verify case is removed (one path); remote ships `verify <pkgs>`; `--verify install` alias kept; `--no-verify` ignored for verify. Pinned `shell-router.bats` messages/rc reproduced, so those tests stay unmodified.
- **uninstall action**: optional `pkg/<name>/uninstall.sh`; absent leg = clear error, nothing changed, non-zero (no guessed teardown); per-package failure collection; deps never removed (consent-gated, ROADMAP "Dependency garbage collection"); verify not run; uninstall forwards the same resolved vars as install/configure; `remove|rem|r` aliases implemented (were documented but unknown).
- **parser**: empty package list and a flag after the action now error clearly; `verify`/`uninstall` require a known cloudify package; install's native apt fallback untouched.
- **pre-existing verify var bug fixed (constraint a)**: verify loaded the pkg yaml in overwrite mode, clobbering a parent override the walker had forwarded. Proven pre-existing by running the repro against `4378e71`. Now the yaml load is fill-only (temporary claim ledger), so walker/caller values survive and unset names still load.
- **Tests**: new `tests/unit/actions.bats`, `uninstall.bats`, `verify-vars.bats`, `tests/integration/package-uninstall.bats`, fixture `pkg/fixture-uninstall`; full unit 386 green; shellcheck clean (lint glob now covers `pkg/*/uninstall.sh`); merge gate `package-uninstall` + `package-install-run-split` PASSED. One cold-start flake observed and re-run green.

### 2026-09-09 - branch 3 gate: payload via stdin description + plan

- Read-only trace (subagent delegation failed twice; done directly) of the remote payload build/transport: payload is the last ssh argv (`lib/remote.sh:312-317`); template ends with a global `exec ... </dev/null` (`:84`); exit code via pipefail into `.exit`; no sshpass/`-t` on this path.
- Proven landmine: `bash -s` reads the script from stdin, so the global `exec </dev/null` truncates the payload (repro `~/tmp/b3/`: small script loses everything after `exec`; 10k-line script loses all). Per-command stdin redirects are safe.
- Plan: local 0600 payload file + `ssh host 'bash -s' < file` (no secret in argv, no pipe SIGPIPE race); per-command `</dev/null`; pinned `remote-vars.bats` ssh stub must read stdin (mechanism only); skill Security section. Consent pending.

### 2026-09-09 - branch 3: payload via stdin + test output standard

- **Payload transport**: `ssh host 'bash -s' < payload` from a 0600 local temp file; the payload is never in argv, so no secret in the operator or host process list. Proven landmine: the template's global `exec </dev/null` truncates `bash -s`; removed it and redirect stdin per command (bootstrap, `cloudify init`, `cloudify $*`).
- **Test output standard**: `tests/helpers/report.bash` (`rubric`/`subrubric`/`step`, timestamped) writes to fd 9 when the runner opens it, so lines stream live through bats. Runner: `bats -T --show-output-of-passing-tests | tee results/<name>.tap`, prints the numbered plan. Tests retrofit: `package-uninstall`, `package-remote-vars` (later deleted).
- **Deleted as redundant**: `tests/integration/package-remote-vars.bats` + `pkg/fixture-env`. Race guard is the unit `remote-vars.bats`; single-host forwarding is `package-install-run-split.bats:64-67`; payload baking is `remote-vars.bats:39-47`. The second container cost ~50s + a readiness flake.
- **Skills split**: `cloudify` (usage), `cloudify-dev` (framework), `cloudify-pkg-dev` (recipes + the test workflow).

### 2026-09-09 - test output standard persisted

- AGENTS.md SDLC: test output standard (rubric/subrubric/step on fd 9, background + poll `results/<name>.tap` with plain tail, no grep, no invented log, e2e last).
- Skills split: `cloudify` (usage), `cloudify-dev` (framework), `cloudify-pkg-dev` (recipes). The full test standard is in both dev skills.

### 2026-09-09 - branch 4: guacamole 3-leg rewrite (reference package)

- **3-leg lifecycle**: install provisions (create-if-absent `.env`/compose, `up -d --wait postgres guacd`, one-time schema init); configure configures (rewrite, converge the postgres role password via the container local socket, converge the admin hash + rename, upsert the RDP connection); new `uninstall.sh` (`docker compose down -v` then remove the project dir) - the trap 3 fix.
- **Trap 7**: admin default `rbc` -> `guacadmin`; `.remote-vars` now declares `CLOUDIFY_GUACAMOLE_ADMIN_USER`; `verify.sh` fallback synced; README updated.
- **Tests**: `package-guacamole.bats` rewritten to the report standard (rubric/subrubric/step, fd 9 live, `setup_file` readiness, base URL derived from the deployed `.env`), 7/7 green. Schema init kept as docker cp + psql (initdb.d evaluated, not adopted).
- **Infra**: `itest-base` carried a stale `guacamole_guacamole_pgdata` volume with the old `rbc` DB; removed and re-baked. Test hermeticity vs the operator's `pkgs/guacamole.yaml` (supplies the bind) noted.

### 2026-09-09 - skill constitution: harness is the completion gate

- `cloudify-dev` + `cloudify-pkg-dev`: added a `## Constitution` rule (bats harness = completion gate, never the debugger; prove cheaply, run once) and trigger-rich descriptions so they autoload. AGENTS.md SDLC nudges reading them before editing.
- Descriptions simplified to the plain triggers (develop/upgrade/debug the tool; write/upgrade/modify packages); AGENTS.md names them as skills.

### 2026-09-09 - branch 5: xfce alignment

- **Declaration**: `pkg/xfce/.remote-vars` now uses the three-kind standard (`CLOUDIFY_XFCE_USER=gui`, `CLOUDIFY_XFCE_USER_PASSWORD=`, `CLOUDIFY_XFCE_SESSION=startxfce4`, `CLOUDIFY_XFCE_RDP_PORT=3389`, `CLOUDIFY_XFCE_INSTALL_CHROME=true`, `CLOUDIFY_XFCE_UNINSTALL_USER=`); `vars declared xfce` prints them.
- **Uninstall**: new `pkg/xfce/uninstall.sh` purges packages + disables/removes xrdp, deletes the state file; the account is removed only with `CLOUDIFY_XFCE_UNINSTALL_USER=true` and the home is never removed. Purge waits on a concurrent dpkg lock (`-o DPkg::Lock::Timeout=300`); shadow untouched.
- **Tests**: `package-xfce.bats` rewritten to the report standard (rubric/subrubric/step, fd 9 live, `setup_file` readiness), uninstall coverage added, 7/7 green. L1 proof on the container for the uninstall leg.
- **Findings**: shadow `sudo` requires a password (`--on localhost` probes must set `CLOUDIFY_LOCAL_PWD`); one gate run was lost to a ~64-min host suspend (ssh dropped, install had succeeded remotely).

### 2026-09-09 - roadmap: two failure modes to study

- Added non-urgent ROADMAP entries: apt dpkg lock race (shadow install/update lack a lock wait) and shadow sudo requiring a password even as root (silent die).

### 2026-09-09 - plan: branches 7+8 collapsed

- Branch 7 is now "state registry + `cloudify deployment run`" (was two branches); Branch 8 removed. Branch 6 stays agent runbooks + amnesiac validation.

### 2026-09-09 - branch 6: agent runbook + amnesiac validation (blocked)

- Wrote `runbooks/xfce-guacamole/disposable.md` + `runbooks/README.md`; retired `plans/xfce-guacamole-e2e.md` to `plans/archived/`.
- Amnesiac validation run twice with a fresh agent (only the cloudify skill + the runbook). Run 1: 7 defects, all fixed (missing deployment activation, broken bind derivation, wrong `ivps info`, missing tag-authkey refresh, no reachability check, wrong re-run wording). Run 2: `ivps acl` syntax, bare-name Incus resolution, false loopback assumption (operator yaml sets the bind); runbook fixed to set a loopback bind + `ivps expose-direct`.
- Blockers recorded as non-urgent ROADMAP entries: no clean node-MagicDNS-FQDN command, `cloudify host`/`info` gaps, tag-to-tag reachability, guacd MagicDNS check. End-to-end pass not yet green.
- Run 3 with provided instances and the software-only scope reached the human gate; clarity frictions fixed. Code fixed: `cloudify host`/`info` no longer crash, guacd MagicDNS check added to guacamole verify, runbook rewritten to software-only.

### 2026-09-10 - runbook fix from the human gate

- The render gate caught RDP auth failure for `gui`: the runbook relied on ambient deployment context, so `CLOUDIFY_DEPLOYMENT` was not set for the xfce install, `CLOUDIFY_XFCE_USER_PASSWORD` was not forwarded, and the recipe generated its own password (which a re-run cannot change, by design). The Guacamole record had the operator password, so auth failed.
- Fix: the runbook now scopes the deployment explicitly per command (`--deployment xfce-gui` for vars, `CLOUDIFY_DEPLOYMENT=xfce-gui` for install/configure/verify/uninstall) and documents that the xfce password is consumed only at account creation. Recovery on the test guest: set the account password to the operator value.
- Human gate PASSED after the scoping fix; teardown ran (xfce + guacamole uninstall, unexpose, deployment delete, guest delete, ACL revoke). Branch 6 done.

### 2026-09-10 - branch 7 gate (state registry + `cloudify deployment run`): description + realignment

- Gate steps 1-2: read-only description artifact (file:line evidence, repros `~/tmp/b7/`) and plan + non-breakage argument in `plans/urgent-surface-cleanup.md`. Key corrections: no per-node record exists today; `CLOUDIFY_DEPLOYMENT` is not forwarded remotely; a registry write must be operator-side; `ivps delete <host>` (container) never cleans the node tree (only `ivps node delete`).
- Design realigned after review. The earlier plan conflated the registry with replay. Now: registry = observation (status, timestamps, version, value snapshot); playable runbook = the plan (Markdown + typed shell steps, targets by name); values = deployment store + run snapshot; replay = runbook + values (`deployment run` converge, `deployment replay` reproduce), never through the precedence ladder. `cloudify_vars_state_read` dropped.
- Vocabulary: a deployment has `targets` (named slots) bound at run time; "role" dropped.
- Target addressing: `--on X` (exists, kind discovered; node+instance collision = error), `X:` (node), `X:Y` (instance on X), `:Y` (instance on the active/default node); active = per-shell `CLOUDIFY_NODE`; no localhost fallback (localhost is a node like any other); bare/`@tag` names must exist (install never provisions). IPv6 vs `:` delimiter filed non-urgent.
- Storage: `$(ivps node path <node>)/[<instance>/]deployments/<id>/pkgs/<pkg>/config.yaml`. Needs `local` as a real ivps node (`ivps node path local` fails today); fix prompt recorded in the plan Notes.
- Registry distribution moved to non-urgent (durability SPOF; backups must be secret-aware, never git). Target-inventory adapter seam filed non-urgent. Consent given (2026-09-10).

### 2026-09-10 - branch 7 T1: `--on` target addressing

- New `lib/targets.sh` (guard `_CLOUDIFY_TARGETS_LOADED`): `_cloudify_target_resolve <token>` prints `<node>\t<instance>\t<ssh_host>` and dies on an unknown or ambiguous target; grammar `X` (kind discovered; node+instance = ambiguity error), `X:` (node), `X:Y` (instance on X), `:Y` (instance on the active node `CLOUDIFY_NODE`, else ivps `IVPS_DEFAULT_NODE`, else error with the fix). `localhost` = node `local`; no localhost fallback; an unknown bare name stays a plain host (ssh validates reachability). Validation-only: it never provisions.
- Router: every `--on` token (after `@tag` expansion) is resolved before dispatch; the resolved `ssh_host` drives `cloudify_remote`/reports, the triples are kept in `_CLOUDIFY_TARGETS` for the registry (T2/T3). Added `cloudify node use <name>` (mirrors `deployment use`) and the grammar in `usage`. Payload template, envsubst allow-list, shadows and recipes untouched.
- Tests: new `tests/unit/targets.bats` (32 cases, rubric/step report) + 4 real-router cases in `shell-router.bats`; red-first run recorded (container had no `lib/targets.sh`). Full unit suite green.
- E2E smoke: all three forms (`cloudai:cloudify`, `:cloudify` with `CLOUDIFY_NODE`, bare `cloudify`) resolve to the same container and the same ssh target; after the tailnet policy was restored, all three returned `cloudify: OK` rc 0 over real ssh.
- Merged to master as `8989e32` (--no-ff); unit suite 425/425.

### 2026-09-10 - RDP ACL post-mortem: tag-scoped grant encoded in the runbook

- ivps post-mortem (this date) root-caused the branch-6 e2e damage: the runbook hardcoded a blanket `ivps acl grant tag:incus --src tag:incus --port 3389` (any-to-any, served neither endpoint), and the teardown ran a narrowed-looking `ivps acl revoke ... --ssh` which, because of an ivps bug (now fixed upstream: source-scoped revoke, no-match revoke is a no-op, empty ssh destination fails lint, UTC snapshots), stripped `tag:incus` from every ssh rule and emptied the lighthouse rule's destination list. Container SSH from the workstation stayed broken ~14h.
- cloudify fix (docs only, branch `docs/rdp-targeted-grant`): the runbook precondition now declares two role tags (`tag:rdp-client` on the guacd host, `tag:rdp-server` on the desktop, `ivps tag set` keeping `tag:incus`) and one scoped grant `ivps acl grant tag:rdp-server --src tag:rdp-client --port 3389`, with a verify step and a scoped policy teardown; `runbooks/README.md` gains the ivps/Tailscale policy rules (identity-only selectors, additive-intent tags, `--ssh` needs `--src`, record the snapshot, teardown proves the policy diff, validate commands against the tool's usage); the archived e2e plan is annotated for its invented `--dst` syntax and non-additive `--tag`.
- Resolved 2026-09-10: the operator restored the policy; container SSH works and T1's e2e smoke is green over real ssh.
