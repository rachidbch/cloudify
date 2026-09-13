# Cloudify session log

## 2026-08-31

- Recorded the successful XFCE and Guacamole oracle and the next Omarchy VM automation path.
- Aborted and trashed the mistaken local Omarchy ISO download before any VM creation.

## 2026-08-31 (session 2) — Omarchy parked

- Root-caused the cloudstation SSH blocker: `/etc/hosts` pinned cloudstation to its public IP, bypassing MagicDNS. Pin removed by user; `ssh cloudstation` now goes over tailnet (MagicSSH), no passphrase needed.
- Exa-grounded every plan assumption: Arch + Hyprland base, v4.0.1 ISO + checksum, Incus ISO/cidata mechanics, xrdp/Wayland incompatibility, wayvnc as the community remote-desktop path, no container precedent (domarchy/devmarchy findings).
- User decisions: no Incus VM on the 8 GiB host; Omarchy deferred until community container support exists. ADR-016 supersedes ADR-015.
- Minted the tag:incus authkey via `ivps tag create incus` (reported; reusable; expires 2026-09-01 02:05).

## 2026-08-31 (session 2 cont.) — Guacamole admin password reset

- User lost the Guacamole web-admin (`rbc`) plaintext; reset via the SOP hash formula against `guacamole_db`. Guacamole 1.6.0 schema fact: `guacamole_user` has no `username` column — the login name lives in `guacamole_entity.name` (joined via `entity_id`), a departure from the SOP's older-schema wording.
- New random salt + password generated on cloudstation (never echoed), `UPDATE guacamole_user SET password_hash/password_salt/password_date WHERE entity_id=(... name='rbc')`, verified via `POST /api/tokens` → 200 + token.
- Credentials persisted to `/home/rbc/guacamole/.env` (`GUACAMOLE_ADMIN_USER`, `GUACAMOLE_ADMIN_PASSWORD`, mode 600); temp state file removed.

## 2026-08-31 (session 2 cont. 2) — guac-gui auto-tiling + XFCE theme investigation

- Enabled **Cortile** auto-tiling on `cloudstation:guac-gui` (pinned v2.5.2, SHA256 verified, installed to /usr/local/bin, XDG autostart for the gui user). Verified live: windows auto-tile on open (Pop!_OS-style), no keybinding needed. Snapshot `guac-gui-cortile` taken.
- Wallpaper set to the user's chosen image (transferred laptop→cloudstation→container to /usr/share/backgrounds/modern.png).
- **XFCE GTK/icon theming is blocked by a known upstream bug**: under xorgxrdp the virtual X server lacks XI2, so xfsettingsd cannot own `_XSETTINGS_S0` → GTK apps get no theme. Config is correct (Arc/Papirus) but unrendered. Receipts: Launchpad #354830 (affects 20, "no gtk theme" when XI absent via xrdp/VNC), Xfce forums #8112 & #8603. Parked by user decision.
- Themed attempts left strays; cleaned up xfsettingsd + temp files. Theme bug parked; substantive goals (Cortile tiling, wallpaper, speed) delivered.

## 2026-08-31 (session 2 cont. 3) — guac-gui final polish; Guacamole letterbox fixed

- Diagnosed the "black strip top/bottom" as **Guacamole client letterboxing**, not XFCE — the RDP connection used Guacamole's default fixed resolution; the client scaled it to the browser preserving aspect, padding the mismatch with black. Confirmed via right-click (strip showed the browser menu, not XFCE).
- Fixed by setting the `cloudstation GUI` connection's `resize-method=display-update` in guacamole_connection_parameter → the RDP session now dynamically resizes to the browser window (resolution went 1536x729 → 1536x864, no letterbox). Verified: xrdp + tailscale + Cortile healthy after resize.
- Final persistent guac-gui state: Cortile auto-tiling (autostart), user wallpaper, no desktop icons, xfwm compositing off, Guacamole display-update. XFCE GTK theme still parked (known xorgxrdp XI2 bug).

## 2026-08-31 (session 2 cont. 4) — guac-gui sudo + name fix

- `gui` added to `sudo` group on `cloudstation:guac-gui` (active on next login). Note: deviates from the SOP's default "gui non-sudo"; this is a live-instance manual approval, not a package-default change. `gui` password recovered from the Guacamole connection record (`cloudstation GUI` username/password) — see HISTORY for the duplicate-device name fix.
- Duplicate `guac-gui` tailnet device resolved: deleted `cloudai:guac-gui` (`.100`); survivor `cloudstation:guac-gui` (`.12`) renamed back to plain `guac-gui` in the Tailscale console.

## 2026-09-07 — session close: journal + handoff

- Journal entry created (2026-09-07, Obsidian): project-oriented onboarding note for the guac-gui + Guacamole oracle (components, connect workflow, next steps) after a first draft was rejected as process narration.
- Codex desktop app installed on guac-gui earlier via the chatgpt .deb (self-contained; the Vercel checkpoint is only on the landing page, not the GitHub/releases assets). See HISTORY 2026-08-31 for guac-gui events.
- HISTORY has a 2026-09-07 re-verify entry (commit 7cb2541); PLAN.md still points at the unrelated k3s plan. No active cloudify work unit beyond the SOP draft.

## 2026-09-07 (session 2) — pkg/guacamole

- Built pkg/guacamole (split, ADR-008) per plans/guacamole-pkg-plan.md; gate artifacts + plan moved tmp/plans → plans/ (committed 1224fd5).
- Debug saga: tailnet identity staleness on cloudai:cloudify after itest-base restores (re-auth via fresh tag:incus key + re-snapshot); WEBAPP_CONTEXT/ROOT missing; then root cause: pkg_depends local-var leak skipping configure.sh on install (fix 2780238). Integration 5/5 green (4645ece).
- Process post-mortem with Rachid: cheap-first probe ladder, no silent test steps, use cloudify's built-in logging, oracle-first config verification. Skill updated (cloudify SKILL.md "Debugging a recipe").

## 2026-09-07 (session 3) — pkg/xfce + E2E

- pkg/xfce shipped, integration 5/5, E2E acceptance passed (human render via deployment xfce-gui). ADRs 017/018/019; plans archived (guacamole, xfce-pkg); runbook plans/xfce-guacamole-e2e.md.
- Sessions debugging discipline distilled into the cloudify skill: L0-L4 ladder, cheap proofs on the tested container, verify-heartbeat, errexit suspension, exit-marker polling, raw log reads. Framework: verify heartbeat landed (bfa1016); errexit-restore rejected by gate.
- Infra: cloudai:cloudify re-authed (tailnet identity), itest-base re-baked (valid identity + baked images, no codebase). Disposable E2E targets still up: cloudai:xfce-test + guacamole on cloudify container (teardown optional).

## 2026-09-07 (session 4) — surface-cleanup design

- Traps 1-7 reviewed one by one; every resolution in ROADMAP URGENT + decided blocks (vars CLI/declaration, vars internals+security, target config model, runbooks a/b).
- Two false trap claims corrected by reading lib/remote.sh (env-only declaration gating).
- Wrote plans/urgent-surface-cleanup.md (8 branches, progress checkboxes) and repointed PLAN.md.
- No cloudify code changed this session. Disposable E2E infra still up (cloudai:xfce-test, guacamole on cloudai:cloudify, deployment xfce-gui) — teardown optional.
- Next: branch 1 (vars internals) behind the CRITICAL GATE description subagent.

## 2026-09-09 — branch 1 gate description + plan consolidation

- Read-only description subagent traced the current var forwarding/precedence machinery; 30 empirical repros in `~/tmp/vars-desc/`. Corrected 5 documented claims, found 2 live hazards (xargs value corruption, no reserved-name guard).
- Rachid mandate: all planning/progress tracked in `plans/urgent-surface-cleanup.md` alone. Rewrote it as the single URGENT tracking file (80 tasks, `[ ]/[~]/[x]/[v]` markers, Branch 1b added, invariants/landmines/resolutions inlined) and trashed the standalone description artifact.
- No code change. Next: finish the branch 1 plan section, then request explicit consent before editing lib/router.

## 2026-09-09 — branch 1 execution (vars internals)

- TDD in `cloudai:cloudify`: wrote `tests/unit/vars.bats` red first, then `lib/vars.sh` + `lib/secrets*` + walker + router R1. 40/40 new, 345/345 unit, 2/2 pinned integration, shellcheck clean.
- Review found the write-side L4 gap (multi-line value truncated at first newline); fixed by encoding `@base64:` in `_cloudify_vars_file_set` + a round-trip test.
- Found + fixed a latent errexit abort in the dep scan (recipe without `pkg_depends`); proved via the local-path test.
- I5/L9 vs target precedence contradiction documented in the plan + HISTORY; resolver-on-env deviation documented (double-resolution across the SSH hop).

## 2026-09-09 — branch 1 merged

- E2e merge gate on final HEAD: unit 345/345, `package-remote-vars.bats` + `package-install-run-split.bats` PASSED. Merged `feat/branch1-vars-internals` to master as `397c064` (--no-ff).
- AGENTS.md/CLAUDE.md "Configuration" bullet corrected (consent); AGENTS.md is a symlink to CLAUDE.md, one edit covers both.

## 2026-09-09 - branch 1b gate

- Description subagent traced the vars CLI/declaration/write surface (read-only); plan + resolutions R1b-1..11 written into the plan file. Consent pending before edits.

## 2026-09-09 - branch 1b (vars CLI)

- Implemented scope flags + `--` sentinel, declaration kinds + kind column, write-time `@` validation (A), byte-preserving stdin, `vars declared --sources` + masking, pure-bash `--json`. 367/367 unit, shellcheck clean, `package-remote-vars` e2e + CLI smoke green. One vars.bats test precondition updated (R1b-7). R9 masking conflict flagged (opt-in `--mask` proposed).

## 2026-09-09 - R9 masking/reveal/resolve

- Secrets opt-in at the CLI: mask by default, `--reveal`, `--resolve`. Library functions stay raw (pinned tests hold). 372/372 unit, shellcheck clean, container smoke green.

## 2026-09-09 - branch 2 gate

- Read-only description of verify/uninstall action surface; plan + R2-1..12 written into the plan. ROADMAP non-urgent "Dependency garbage collection" added. Consent pending.

## 2026-09-09 - branch 2 (verify + uninstall)

- verify is a first-class action local/remote; uninstall runs optional uninstall.sh, refuses absent legs, never touches deps, forwards resolved vars; parser errors fixed; remove|rem|r aliases. Fixed the pre-existing verify yaml clobber (fill-only load) proven against 4378e71. 386/386 unit, shellcheck clean, package-uninstall + install-run-split integration green.

## 2026-09-09 - branch 3 gate

- Traced payload transport; proved `bash -s` + global `exec </dev/null` truncates the payload. Plan R3-1..6 written (stdin via 0600 local file, per-command stdin redirects, pinned ssh-stub update, skill Security section). Consent pending.

## 2026-09-09 - branch 3 (payload via stdin) + test output standard

- Payload on stdin from a 0600 file; per-command stdin redirects (global `exec </dev/null` truncates `bash -s`). Live report helper (fd 9) + runner tee to `.tap`. Deleted redundant `package-remote-vars.bats`/`fixture-env`. Skills split into cloudify/cloudify-dev/cloudify-pkg-dev.

## 2026-09-09 - test output standard persisted

- AGENTS.md line + test standard in cloudify-dev and cloudify-pkg-dev. Skills split done.

## 2026-09-09 - branch 4 (guacamole 3-leg)

- install provisions / configure configures (DB role + admin convergence) / uninstall `down -v`; admin `guacadmin`; ADMIN_USER declared; verify synced. bats rewritten to the report standard, 7/7. Re-baked itest-base after removing a stale guacamole volume.

## 2026-09-09 - skill constitution

- Constitution rule + autoload-friendly descriptions in cloudify-dev/cloudify-pkg-dev; AGENTS.md nudge.

## 2026-09-09 - branch 5 (xfce alignment)

- Three-kind declaration, new uninstall leg (explicit account removal, home preserved), README, bats to the report standard, 7/7. Purge waits on the dpkg lock; shadow untouched.

## 2026-09-09 - branch 6 (runbooks a)

- Runbook + rules written; two amnesiac validation runs, defects fixed; end-to-end blocked by recorded tooling gaps (node FQDN, tag-to-tag ACL, guacd DNS).

- Run 3 (instances provided, domain given) reached the human gate; runbook rewritten to software-only scope; `cloudify host`/`info` crash fixed; guacd DNS check added.

- Human gate failed on xfce RDP auth: runbook didn't scope the deployment per command, so the xfce password var was not forwarded and a password was generated. Runbook fixed to scope the deployment explicitly; guest account recovered to the operator password.

- Human gate passed (XFCE render + keyboard) after the scoping fix; full teardown done. Branch 6 done.

- Branch 7 gate started: read-only description artifact (file:line + repros ~/tmp/b7) + plan recorded; design realigned after review (registry = observation; playable runbook + values = replay; targets/bindings; `--on` grammar; storage under the ivps node dir; `state_read` dropped; registry distribution + IPv6 + inventory adapter filed non-urgent). ivps fix prompt (`local` as a node) in the plan Notes.

## 2026-09-10 - branch 7 T1 (`--on` target addressing)

- `lib/targets.sh` resolver (`X`, `X:`, `X:Y`, `:Y`; ambiguity + plain-host fallback; `localhost` = node `local`) + router wiring (`_CLOUDIFY_TARGETS` triples, `cloudify node use`); README/usage updated.

- Tests: `tests/unit/targets.bats` 32 cases + 4 router cases; full unit suite green.

- E2E smoke of the three forms green over real ssh (`cloudify: OK`, rc 0) after the tailnet policy restore; merged to master as `8989e32`.

- RDP ACL post-mortem received (ivps agent): blanket tag:incus->tag:incus grant + over-broad `acl revoke --ssh` (ivps bug, fixed) broke container SSH ~14h. Encoded the tag-scoped replacement (tag:rdp-client/tag:rdp-server) in the xfce-guacamole runbook + runbooks/README policy rules; annotated the archived plan. Policy restored by the operator; container ssh green.

## 2026-09-10 - branch 7 T2 (registry storage)

- New `lib/registry.sh` + router source: record path under `$(ivps node path <node>)[/<instance>]/deployments/<id>/pkgs/<pkg>/config.yaml`, plain-host fallback under `${CLOUDIFY_CREDENTIALS_DIR:-$HOME/.config/cloudify}/registry/hosts/<ssh_host>/...`; `file`/`put`/`get`/`delete`/`list`, 0700/0600, atomic mktemp+mv, unsafe components rejected.
- Tests: `tests/unit/registry.bats` 27 cases (red first, then green); driver `~/tmp/t2/driver.sh` green; `task lint` rc 0; `task test-unit` 452/452 rc 0 on final HEAD.
- Pruning stops below `deployments/<id>`; `list` takes an optional ssh_host (fallback bucket only); both recorded in the module header + the plan's T2 outcome.
- Next: T3 registry write (operator-side, after a successful dispatch), T5 reserved names.

## 2026-09-10 - branch 7 T3 (registry write)

- `lib/registry.sh`: record builder/apply (`cloudify_registry_record_build`/`_apply`) + `_cloudify_registry_record_bg`; flat schema (`status`, timestamps, deployment/node/instance/package, `version`, `var.<NAME>` raw snapshot); merge keeps earlier timestamps; uninstall = `status: removed` + `removed_at`, record KEPT (supersedes the T4 "uninstall removes the slice" wording; T4 now `deployment delete` only).
- Router: pid-keyed `_CLOUDIFY_BG_ACTION/_PKGS/_TARGET` + `_cloudify_note_bg`; local triple `local//localhost`, remote triple from `_CLOUDIFY_TARGETS` (no extra ivps call); the wait loop writes a record per package on success only; verify and an unset `CLOUDIFY_DEPLOYMENT` are skipped.
- Tests: `tests/unit/registry-write.bats` 12 cases + 1 `shell-router.bats` case; `task lint` rc 0; driver `~/tmp/t3/driver.sh` green; full unit suite 465/465 rc 0 (`1..465`, once on final HEAD).
- E2E: throwaway-deployment install on `cloudai:cloudify` wrote `~/.config/ivps/nodes/cloudai/cloudify/deployments/<id>/pkgs/bats-test/config.yaml` (700/600, correct node/instance/timestamp); re-run kept one valid record; throwaway dir trashed.

## 2026-09-10 - branch 7 T4 + T5 (registry cleanup + reserved names)

- `cloudify_registry_delete_deployment` sweeps `${IVPS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ivps}/nodes/*` and `${CLOUDIFY_CREDENTIALS_DIR:-$HOME/.config/cloudify}/registry/hosts/*` for `<root>/deployments/<id>` and `<root>/*/deployments/<id>`, removing only dirs with a `pkgs/` subdir (trash-put, rm fallback, prints each removal, rc 0 when none); no `ivps` call. `cloudify_deployment_delete` calls it after the store trash (also for an orphan id), `declare -F`-guarded; router usage updated.
- `lib/vars.sh` deny-list + `CLOUDIFY_FORCE`, `CLOUDIFY_NO_VERIFY`, `CLOUDIFY_DEPLOYMENT`, `CLOUDIFY_NODE`, `CLOUDIFY_INSTANCE`; warn+skip unchanged.
- Tests: `tests/unit/registry-delete.bats` 14 cases (red first: 13 failed), +1 `vars.bats` reserved-name case. `task lint` rc 0; focused 82/82 and 57/57 in `cloudai:cloudify`; full `task test-unit` 480/480 rc 0 (`1..480`, once on the final tree).
- E2E: two throwaway ids installed on `cloudai:cloudify` -> records under `~/.config/ivps/nodes/cloudai/cloudify/deployments/<id>/pkgs/bats-test/`; `cloudify deployment delete <id>` removed one id's record + store dir and printed it; sibling record, `node.json`, bucket intact; both ids trashed after.

- Branch 7 T8+T9: added ADR-020 (registry=observation, replay=runbook+values, targets/bindings, secrets refs-vs-raw; supersedes ADR-011 pts 3/6/7), annotated ADR-011 status, added lean Security sections to the cloudify-dev and cloudify-pkg-dev skills. Docs only.

- T6 design note written into the plan (runbook = Markdown front-matter + typed shell steps; targets as TARGET_<NAME>; bindings from --target or the deployment store; step outputs via CLOUDIFY_OUTPUTS_FILE; `deployment run` with preflight via `vars declared`; run snapshot under the deployment store; `replay` exports the snapshot). Awaiting approval before implementation.

## 2026-09-10 - branch 7 T6a (runbook parser + preflight + `deployment run --dry-run`)

- New `lib/runbooks.sh` + router source + `deployment run` verb. Contract: `cloudify_runbook_parse` (`type\tid\ttarget\tpkg\tbody-b64`), `cloudify_runbook_meta` (`deployment\ttargets-csv`), `cloudify_runbook_find` (default `${CLOUDIFY_DIR}/runbooks`), `cloudify_runbook_bind_targets` (`name\tnode\tinstance\tssh_host`), `cloudify_runbook_preflight`.
- Parse validates `bash step=<type> [target=] [pkg=] [id=]`; dies with path + line on unknown type/attribute, missing target/pkg, undeclared target, duplicate id; auto id = position `%02d`. Bindings: `--target` > store `TARGET_<NAME>`; unbound dies listing all. Preflight honours the runbook's deployment store and dies listing every unresolved `pkg: NAME`. `--dry-run` prints the plan (deployment, targets, steps) and exits 0; without it the plan prints then dies for T6b.
- Ambiguities recorded in the plan T6a note: non-step fences ignored, unknown attribute fails closed, duplicate front-matter targets deduped, `--runbook` deployment must match `<id>`, `--from` validated but unused, `--yes` ignored, pkg need not exist.
- Tests: `tests/unit/runbooks.bats` 22 cases + fixtures `tests/fixtures/runbooks/{valid,guest-only}.md`; `task lint` rc 0; driver `~/tmp/t6a/driver.sh` green; focused 67/67; full `task test-unit` 502/502 rc 0 (`1..502`, once on final HEAD).

## 2026-09-10 - branch 7 T6b (runbook execution + outputs + human gate + run snapshot)

- `cloudify_runbook_execute <path> [--target ...] [--from <id>] [--yes]`: preflight, run-wide `CLOUDIFY_DEPLOYMENT`/`TARGET_<NAME>`/`CLOUDIFY_OUTPUTS_FILE`, per-step `STEP_*`, `bash -c` body streamed (stop at first non-zero, report step id), outputs file `name=value` -> `OUT_<name>`, `human-gate` body + TTY confirm (or `--yes`). Snapshot `${CLOUDIFY_DEPLOYMENTS_DIR}/<id>/runs/<utc>.yaml` (0600, atomic) with `status`/`started_at`/`finished_at`/`runbook`/`target.*`/`value.*`/`output.*`; written on failure too.
- Router: `deployment run` without `--dry-run` dispatches it; `--from`/`--yes` now effective; usage updated.
- Design's `cloudify_vars_deployment_file` absent -> used `_cloudify_deployment_config`.
- Tests: `tests/unit/runbook-exec.bats` 6 cases; `runbooks.bats` non-dry-run case now asserts execution. `task lint` rc 0; driver `~/tmp/t6b/driver.sh` green; focused 73/73; full `task test-unit` 508/508 rc 0 (`1..508`, once on final HEAD).
- E2E: throwaway `t6b-smoke` runbook (real `verify bats-test` over ssh + an output step) -> rc 0, snapshot 600 with `output.stamp`; deployment deleted after.

## 2026-09-10 - branch 7 T6c (`deployment replay`)

- `cloudify_deployment_replay <id> [--at <run>] [--runbook <path>] [--target ...] [--from <id>] [--dry-run] [--yes]`: `--at` = existing path / basename / timestamp prefix under `deployments/<id>/runs/`, default = most recently written (mtime); none or several -> die listing them. Seed: `target.<name>` -> binding (CLI `--target` wins), `value.<NAME>` -> `_cloudify_resolve_var_value` (reference decoded) + export (steps/ladder read it; the env path is a pass-through), runbook from the snapshot (`--runbook` overrides). Then the `deployment run` engine: preflight + steps + new snapshot. Plan prints target addresses and value names only; values never printed or on argv.
- `CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES=<snapshot>`: the new snapshot records the replayed `value.*` lines, not the store's current state (unset = old behavior).
- T6b artifact fixed (found by the E2E): a same-second run/replay overwrote `<utc>.yaml`. Engine now suffixes `-2`, `-3`, ...; the selector's newest is mtime-based; `runbook-exec.bats` newest assertion -> `_newest_snapshot`.
- Fail closed: framework-owned/malformed value names, a non-snapshot file, a missing snapshot runbook.
- Tests: `tests/unit/runbook-replay.bats` 11; `task lint` rc 0; driver `~/tmp/t6c/driver.sh` 18/18; focused 163/163; full `task test-unit` 519/519 rc 0 (`1..519`, once on final code HEAD).
- E2E: `t6c-smoke` run (source `deployment`) -> store var deleted -> plain run fails preflight -> replay rc 0 with source `env`, value absent from the log, second 0600 snapshot with `-2` suffix; throwaway deleted.

- T7 runbook authored as data + engine `run` step type + guacamole admin-user declaration fix; 520/520 unit. E2E blocked: invalid tailnet auth key (worked around with --tag incus) and invalid Tailscale API token (401 on tag/acl writes). Guest up; branch unmerged.

- T7 cheap proofs green: dry-run/preflight; xfce installed+verified on cloudai:xfce-test; guacamole installed+configured+verified on cloudai:cloudify (GUI connection to xfce-test...:3389). E2E blocked on the single missing rule rdp-client->rdp-server:3389 (xrdp listens; workstation reaches it; gateway cannot). Applying it needs the API token, 401 today.

- Tailscale API token deep diagnosis: client-side clean, single well-formed token, 401 on both schemes/endpoints and on tailnet/-; worked at 16:28Z today; no revocation logged in either repo. Cause = expired or revoked (console-only disambiguation). Rule creation blocked until a valid token exists.

- Tailscale API 401 root-caused: the token is well-formed and correctly read; it worked at 16:28Z today; no revocation logged. Provisioned 2026-06-12 (expose-service) = exactly 90 days today -> default API-key expiry. Also found: `ivps init` asks for `tskey-client-...` while the code uses the value directly as an API token (`tskey-api-...`). Console confirms expired vs revoked.

- Scoped RDP rule created + verified: tags rdp-client (cloudify) / rdp-server (xfce-test), grant 3389; gateway->guest probe TCP-OPEN. E2E awaiting go-ahead.

- E2E #1 surfaced a runbook-engine bug: step bodies inherited the loop's stdin and stole the remaining steps -> truncated run reported success. Fixed (array-fed loop + `</dev/null>` bodies), red test added, focused suites green.

- Branch 7 T7 done: E2E walked the plan to the human gate, gate PASSED, teardown done (test stack only; rdp rule + tags kept, permanent guac untouched). Docs synced: README/AGENTS/CLAUDE, cloudify + cloudify-dev skills, runbooks/README, pkg/guacamole/README. Plan archived.

- Layer 1 (docs): runbook teardown contract added (README) + xfce+guacamole teardown rewritten with explicit ids/order; Layer 2 (engine `phase=` separation) roadmapped.

## 2026-09-12 - state model v2 design review

- Adversarial review rejected ADR-021 as an implementation contract: it removed the only first-install and cross-host value scope, duplicated physical package truth per deployment, used an ambiguous and path-invalid deployment identity, discarded current target bindings, omitted a crash-safe event/state protocol, and allowed captured output to persist secrets.
- ADR-022 supersedes it: one private dispatch context, retained desired inputs, tuple identity, deployment manifest, one physical package record with claims, explicit secret metadata, event-first revisioned commits, claim-aware pinned teardown, and no event replay.
- `REDESIGN.md` and `GLOSSARY.md` rewritten; detailed gated plan created at `plans/state-model-v2.md`; old implementation plan archived. No runtime file changed and the CRITICAL GATE remains closed.

## 2026-09-12 - G1 description (read-only)

- Spawned one read-only subagent for G1 only (no planning, no code). Its probes live in `~/tmp/state-model-v2-probes/`; all 11 re-run rc 0.
- Artifact: `plans/state-model-v2-description.md` (1100 lines, 249 unique `file:line` citations). Covers value flow, the `envsubst` payload, the four shadows, dispatch/transport, runbooks, `pkg_depends` and the observability gap, registry and deployment writes, plus 34 positive invariants for G2.
- Verification by me, not trusted from the child: every cited line resolves within its file; a spread sample matched its claimed subject; the 25-token allow-list and the 0600 payload/stdin transport matched `lib/remote.sh`; swallowed exit codes matched `lib/shadows/{apt-get,git}.sh`; the depth-prefix defect matched `lib/package-api.sh:416`.
- Not proven, carried into the artifact's uncertainties: no live remote dispatch, gist body quoted from the pinned raw URL, probe semantics pinned to envsubst 0.21 and bash 5.1.16, ivps bucket resolution for `local` inferred.
- No file under `lib/`, the router, `shadows/`, `pkg/` or `tests/` changed. `git status --short` shows only docs.

## 2026-09-12 - G2 non-breakage argument

- Wrote `plans/state-model-v2-non-breakage.md` (306 lines). Touch matrix over `remote.sh`/router/shadows/package API/runbooks/storage/ivps for all nine phases, the six proofs the plan demands, per-phase invariant risk list, section 5 read-before-write ordering, section 7.1 rollback boundaries and files per phase, section 7.2 the eight-item behavior change set consent would cover.
- Grounded on the accepted G1 invariants and re-checked against code: shadow family untouched by every phase (plan greps), snapshot replay needs only a `runbook:` line (`lib/runbooks.sh:856-857`) so dropping `output.*` stays readable, `_CLOUDIFY_VARS_RESERVED` lacks `HOME` (the collision hazard is pre-existing).
- No runtime file changed. `git status --short` clean after commit.

## 2026-09-12 - G3 consent: Phase 1 approved

- Rachid approved Phase 1 of `plans/state-model-v2.md` (characterize the defect, freeze identity rules and JSON schemas, migration fixtures). Exact scope: `tests/`, new schema/fixture files, `plans/` and docs. No runtime file: nothing under `lib/`, the `cloudify` router, `pkg/`, or ivps.
- Consent is scoped to Phase 1 only. Phase 2 and beyond need a new consent gate, as does every item in G2 section 7.2's behavior change set, SSH host-key pinning (still undecided: opt-in for one release vs fail-closed), and any harness-file edit.
- Also approved: push the documentation commits, and one feature branch for this slice.

## 2026-09-12 - Phase 1 executed

- Two parallel subagents on `state-model-v2-phase1`: A for identity rules, schemas and migration fixtures under `schemas/`; B for the characterization and red tests under `tests/`. Disjoint file sets.
- A: `schemas/v1/{identity.md,README.md,validate.sh,lib/schema-check.jq}`, four schemas, 34 fixtures, 7 migration fixtures, inventory-only migration report. B: `tests/unit/state-v2-characterization.bats` (3 green), `tests/red/state-v2-duplicate-resolution.bats` (2 red), `tests/red/README.md`.
- I verified rather than trusted: ran the validator, ran both bats files in the container (`ok 1-3`, `not ok 4-5` with setup sanity passing), ran the full `task test-unit` (524 ok, 0 not ok, rc 0), checked no em dashes or tables, and confirmed REDESIGN's `values.yaml`/`manifest.json`/`state.json` names match `identity.md`.
- Review found and fixed a live hole: `schemas/v1/lib/schema-check.jq` silently ignored `minProperties`, used by `deployment-manifest.schema.json` for the non-empty `bindings` object. Added `minProperties`/`maxProperties` enforcement plus a fail-closed unsupported-keyword error; proved both with an injected unknown keyword (rc 5) and empty bindings (rejected).
- Deviations recorded in the plan: the red proof runs in the unit harness instead of an integration test (the defect is fully observable there, real code plus stubbed ssh reading stdin), and the application-input mapping case is a red contract test because no mapping concept exists yet.
- README repository map updated with `schemas/` and `tests/red/` so the new directories are discoverable.

## 2026-09-12 - G3 consent: Phase 2 approved

- Rachid approved Phase 2 (one dispatch context, one value resolution) after G2 section 7.2 was presented. Scope: `lib/vars.sh`, new `lib/context.sh`, `lib/remote.sh`, `lib/registry.sh`, `lib/runbooks.sh` and the router wiring, plus tests and docs.
- Interface pinned before code in `plans/state-model-v2-phase2-design.md`: module and API, a metadata-only context file with no plaintext value, the parent-created context path that never reaches argv, the byte-identical payload and registry-record rules with the equivalence proof, the single accepted behavior change, and the `CLOUDIFY_LEGACY_VARS=1` rollback switch.
- Still requiring a separate consent gate: every other item in G2 7.2, SSH host-key pinning, ivps changes, and any harness-file edit.

## 2026-09-12 - Phase 2 slice 2A: context module

- Added `lib/context.sh` (resolver + metadata-only context file) and `tests/unit/context.bats` (19 tests), plus one sourcing line in the router. Nothing wired yet, by design.
- `lib/vars.sh` gained a single-pass provenance record: `_cloudify_vars_emit` takes an optional source label and appends `name<TAB>source<TAB>reference` to `_CLOUDIFY_VARS_SOURCES` after a successful claim. The no-clobber branch records `environment`, because with the ledger set a claimed name that is already set can only have come from the caller env. That keeps label and value in one pass with no store re-read.
- Review fix during the slice: my first version re-derived the source label by grepping the store files a second time, the exact duplicate-resolution class this phase removes. It was rebuilt on the emit-time record and the second pass was deleted; a structural test now fails if a store read or a `compgen -v` snapshot reappears in `lib/context.sh`.
- Verified: `tests/unit/context.bats` 19 ok 0 not ok, `task test-unit` 543 ok 0 not ok, `task lint` rc 0, shellcheck clean on both files.

## 2026-09-12 - Phase 2 slice 2B-i: payload and dispatch from the context

- `lib/remote.sh`: `_cloudify_context_file_init` creates the 0600 context file in the parent and exports `CLOUDIFY_CONTEXT_FILE`; `cloudify_remote` calls it before backgrounding the per-host sync; the child builds the context and derives the payload name list from it. `_cloudify_dispatch_vars` is the single dispatch entry that parses action and package words and runs `cloudify_context_build`.
- `cloudify`: local install, configure and uninstall subshells build the context in the child while the parent created the path; the path is recorded per pid as `_CLOUDIFY_BG_CONTEXT` for the registry write in slice 2B-ii. Verify skips context init (inv 33 unchanged).
- Payload text proven byte-identical: 16 new tests in `tests/unit/context-wiring.bats` capture the payload twice, with `CLOUDIFY_LEGACY_VARS=1` and without, and `cmp` them over an 8-case matrix (caller env, deployment, package, global, base64 reference, multiline, rightmost wins, dependency). ssh argv carries no path and no value.
- Deliberate non-identical detail: the re-emitted "required var unset" warning uses a hyphen where the legacy text used an em dash; the condition and wording are otherwise the same.
- Verified: `task test-unit` 559 ok 0 not ok, `task lint` rc 0.

## 2026-09-12 - Phase 2 slice 2B-ii: registry, snapshot and preflight from the context

- `cloudify_registry_record_build` takes the dispatch context file and reads `var.<NAME>` from it: reference text verbatim for a reference, the labelled store's raw text for a literal, no precedence walk. Missing or unreadable context warns and writes nothing; it never falls back to a second walk. The context file is removed after the write and on the router's failure path.
- Equivalence proved before deleting anything: 9 cases build the record twice, legacy and context, over caller env, deployment, package, global, caller-env-plus-conflicting-deployment, base64 reference, multiline, unresolved declared name and an undeclared ambient name, and assert full text equality after normalizing only the write timestamps. `_cloudify_registry_raw_var` stays in the tree behind `CLOUDIFY_LEGACY_VARS=1` as the design's rollback rule requires.
- Snapshot: deployment-store keys are kept and a resolver view built once per run corrects or appends the declared names, so no existing line disappears. Preflight selects sources through the same label function as the dispatcher (a spelling mismatch between the two was found and fixed).
- The red gate flipped: `tests/red/state-v2-duplicate-resolution.bats` test 1 is now green (payload = registry = snapshot = caller-value); test 2 stays red, it needs the Phase 3 application input mappings.
- Verified: `task test-unit` 567 ok 0 not ok, `task lint` rc 0.
- Accepted change, recorded: a store value that is present but empty no longer falls through to the next store for the registry record, because the record must agree with the payload; this is G2 7.2 scope.

## 2026-09-12 - Phase 2 gate (2C)

- L1 driver on the container: `cloudify_context_build` exports the literal into the calling shell and writes a metadata-only 0600 context file with the expected labels.
- L2 `cloudify --on localhost --no-verify install fixture-split` OK, L3 `PKG_VERIFY_TIMEOUT=30 cloudify verify fixture-split` verified on attempt 1, `CLOUDIFY_LEGACY_VARS=1` install OK, registry record written from the context path. One integration run (`task test-integration:entr`) passed on the pushed branch.
- Debug hardening: replaced the masked-payload debug rendering with names, source labels and redaction status, plus a test proving neither fixture value nor any `export ...=` payload line appears with `DEBUG=true`.
- Three review fixes this gate: a test that depended on an ambient `/tmp/cloudify`, a self-created context file deleted before the debug rendering could read its labels, and (earlier) the provenance re-read.
- `task test-unit` 568 ok 0 not ok, `task lint` rc 0.

## 2026-09-12 - Phase 3 slice 3A: canonical application tree, phases, input mappings

- Canonical tree `runbooks/<application>/<flavor>/runbook.md` with identity derived from the path; legacy `runbooks/<application>/<flavor>.md` stays discoverable through the legacy engine with the deprecation warning for a `run`/`human-gate` step without a phase.
- Frozen flat syntax, documented in `runbooks/README.md`: `inputs: NAME[, NAME...]` and `map: PACKAGE_VAR=APPLICATION_INPUT[, ...]`, both sides validated against `schemas/v1/identity.md` before any step; a mapping whose input is not declared is rejected.
- Resolver order extended with an `application` rank, strongest last: recipe default < global < package < application default < mapped application input < deployment value for the package variable < caller environment for the package variable; the application input's own value resolves application default < deployment < caller env. Still one pass at the emit point, no store read twice.
- Phase machinery: phase defaults per step type, `phase=` required for `run`/`human-gate` on canonical paths, unknown or contradictory combinations rejected at parse, bare application run selecting install then verify, preflight filtered to the selected phases, `--yes` unable to select teardown, document order preserved.
- The shipped runbook moved to `runbooks/xfce-guacamole/default/runbook.md` with explicit phases on its `run`/`human-gate` steps; every target, id and body preserved. Moved rather than copied, because a copy with the same `deployment:` makes runbook lookup ambiguous.
- The second red proof is now GREEN through the real engine (a canonical fixture runbook whose steps dispatch each fixture package), so both contracts in `tests/red/` hold.
- Verified: focused suites 76 ok 0 not ok, `task test-unit` 580 ok 0 not ok (results/3a-unit.tap), `task lint` rc 0.

## 2026-09-12 - Phase 3 slice 3B: app commands, nested inputs, manifest and state root

- New `lib/state.sh`: the one state root `${XDG_STATE_HOME:-$HOME/.local/state}/cloudify`, 0700 tuple directories, the per-deployment manifest and its `flock`, written atomically, fields exactly `schemas/v1/deployment-manifest.schema.json` with `schema_version: 1`, no applied values. A test proves a written manifest passes the reference checker in `schemas/v1/lib/schema-check.jq`.
- `cloudify app run <app>[/<flavor>] [--name <name>]` exports `CLOUDIFY_APPLICATION`, `CLOUDIFY_FLAVOR`, `CLOUDIFY_DEPLOYMENT_NAME`, prints the full reference in every plan and error, defaults flavor and name to `default`, and reserves `app reconfigure|verify|teardown` with a clear "Phase 4" error.
- Desired inputs: nested `deployments/<app>/<flavor>/<name>/values.yaml` (0700/0600) with read-through to the legacy single-ID store; a nested write fails closed and names the migration command while legacy-only keys would be shadowed. `deployment migrate <id> --application <app>` requires the tuple explicitly, never splits the id, prints an inventory-only dry run and merges idempotently without deleting anything.
- Lifecycle: `applying` before the first mutating step, `active` after install plus verify, `degraded` on failure, interrupted runs left discoverable as `applying`; recorded bindings reused instead of re-prompting; the Cloudify commit recorded with an explicit development override for a dirty tree.
- Verified: `results/3b-unit-verify.tap` 623 ok 0 not ok, `task lint` rc 0.
- Direction recorded from Rachid during this slice: no backward compatibility layers. The legacy dual paths are to be deleted rather than kept behind switches, so the next slice trims them.

## 2026-09-12 - Phase 3 slice 3C: legacy paths deleted (no compatibility layers)

- 3C-i: deleted the legacy value walker (`_cloudify_pkg_remote_vars` and its recursion), the registry raw walk (`_cloudify_registry_raw_var`), the `CLOUDIFY_LEGACY_VARS` switch across `lib/remote.sh`, `lib/registry.sh` and the router, and the dead `cloudify_vars_state_read` stub. Their tests went with them. The safety net moved to byte-exact golden fixtures captured BEFORE the deletion: 8 payload cases and 9 registry record cases under `tests/fixtures/golden/`, compared with `cmp` by `tests/unit/golden-fixtures.bats`, with a README stating that a diff means a deliberate format change.
- 3C-ii: deleted the legacy runbook path discovery and its deprecation warning, the dual front-matter rule, the `CLOUDIFY_LEGACY_VARS` snapshot branch, the legacy single-ID desired-input read-through and its shadowing guard, and the superseded verbs `deployment run`, `deployment create`, `deployment delete`, `deployment use`. Kept `deployment replay`, `deployment show`, `deployment list`, the registry sweep (teardown will call it) and one bridge: `deployment migrate`, now the sole reader of the old `<config-root>/deployments/<id>/config.yaml`, marked temporary in its help text.
- Docs now describe what the code does: `runbooks/README.md`, `README.md`, `schemas/v1/README.md` and the stale `lib/package-api.sh` comment updated. `ADR.md` untouched (append-only).
- Verified after the fixes: red proofs plus characterization and golden suites 23 ok 0 not ok; full unit suite 619 ok 0 not ok (`results/3c-unit-verify2.tap`); `task lint` rc 0. Two follow-ups I fixed myself: the red file still called the deleted `cloudify_deployment_create` and the bare-id store helper, and `lib/context.sh` still described the deleted walker.

## 2026-09-13 - State model v2 recovery: rejected Phase 4 removed, one-path decision, plan re-issued

- Two independent audits found contract violations in the in-progress work. The uncommitted Phase 4A was archived to `~/tmp/cloudify-phase4a-rejected-20260913/` (patch, `lib/state-pkg.sh`, `tests/unit/state-pkg.bats`, `stat.txt`, `SHA256SUMS`, mode 0700) and removed from the repo: flat `key: value` written into a file named `state.json`, a forgeable stdout result sentinel, package-instance identity dropped from state keys, migration fabricating `application_commit`, events deferred past state writes, and a second walk that reopened value stores after context creation.
- Phases 1, 2 and 3 stay on `state-model-v2-phase1` as a repairable baseline, not as specification-complete code. Nothing under `lib/`, the router or `pkg/` changed in this recovery slice; every edit is plan, ADR, schema, fixture or doc.
- ADR-023 accepted: one v2 runtime path, no compatibility reader, writer, switch, alias or legacy discovery. Temporary one-shot migration commands are the sole old-format readers, they remove an old source only after its v2 copy verifies, and they are deleted once the inventory reports zero old artifacts. Rollback is a Git revert plus a pre-migration backup, never a permanent switch. ADR-023 also records the v2 command surface, superseding ADR-022 point 7 spellings that cannot express the tuple.
- `REDESIGN.md` and `GLOSSARY.md` rewritten from "compatibility period" to "Migration and removal"; the `compatibility period` concept is replaced by `migration bridge`. The attempt plan `plans/state-model-v2.md` is archived as `plans/archived/state-model-v2-attempt1.md` and `plans/state-model-v2-phase2-design.md` as `plans/archived/state-model-v2-phase2-attempt-design.md`; every live citation was repointed so no doc points at a deleted file.
- Schemas aligned: the secret classification enum is `explicit|heuristic|none` (`legacy-heuristic` removed from both schemas, two valid fixtures and the docs), and `application_commit` is now `["string","null"]` in the manifest, run and package-state schemas, with one `allOf` rule requiring `development_override: true` whenever the manifest or run commit is null. Four fixtures added (unproved-commit valid for manifest and run, null-commit-without-development-override invalid for both) and the migrated-observation package-state fixture no longer carries a fabricated commit. `bash schemas/v1/validate.sh` is green: 15 valid accepted, 23 invalid rejected, 0 failures.
- The execution plan is re-issued as `plans/state-model-v2-recovery.md` and `PLAN.md` now points at it. Order: R0 clean baseline, R1 Phase 2 repair, R2 Phase 3 audit, R3 fresh Phase 4 design with explicit consent, then Phases 4 to 9. Each phase ends on independent SPEC and Technical reviews that must both return `PASS` with no actionable feedback.
- Consent recorded: the repair-and-complete direction, the no-compatibility decision, and the re-planning of Phase 4 from `REDESIGN.md` plus `schemas/v1/package-state.schema.json` before any Phase 4 code. Phase 4 implementation still needs its own explicit go after R3's design review.
- Test-container contamination found and fixed while closing R0. `task sync` used plain rsync with no pruning and never pushed `schemas/` or `runbooks/`, and the container `/root/cloudify` is an rsync target rather than a git checkout. Consequences: the rejected `lib/state-pkg.sh` and `tests/unit/state-pkg.bats` still ran (7 spurious failures), and schema-dependent unit tests validated against the pre-change `schemas/v1`. Fix: `task sync` now mirrors `lib`, `tests`, `pkg`, `schemas` and `runbooks` with `--delete`, the stale rejected files were moved out, and the suite was re-run from a faithful mirror. Clean result: `1..619`, 619 ok, 0 not ok (`results/r0-unit-clean.tap`), `task lint` rc 0. Unit tests build their own trees under `mktemp -d`, so the missing `runbooks/` never affected them; `tests/unit/state.bats` does use the repo's real `schemas/v1`, which is why the mirror fix matters.
- Gate change from Rachid: every code phase (R1, R2, Phases 4 to 9) now exits on the same Phase exit gate, defined once in the recovery plan. It requires a green full unit suite, the full disposable two-host application end-to-end run, the full fleet E2E (`tests/e2e/k3s-multi-cluster.bats`), proof that every disposable resource and ACL change was restored, and fresh-context SPEC plus Technical reviews that both return exactly `PASS` with no actionable feedback. R0 and R3 are exempt from the E2E lines only, because R0 changes no runtime code and R3 writes none; R3 also keeps its explicit consent gate before Phase 4 code. Two earlier rules that allowed a partial E2E per phase and reserved the full E2E for the final gate are superseded.
- Gate refinement, Rachid's call: the Phase exit gate is two-tier. Every code phase runs the full disposable two-host application E2E, because that is the state-model blast radius (locks, claims, reconfigure, teardown). The fleet E2E `tests/e2e/k3s-multi-cluster.bats` is not per-phase: four throwaway nodes plus a live tailnet ACL mutation plus up to fifteen minutes per node validates k3s UX, not the state model, so it runs once at the Phase 9 final gate with the ACL restore as an exit criterion. Reviews stay per-phase and unchanged.
- CRITICAL GATE step 1 for R1 is done. A read-only subagent wrote `plans/state-model-v2-forwarding-description.md` (627 lines) describing the forwarding path end to end with file:line evidence: `declare -f` payload extraction, the envsubst allow-list, single-quoted remote `$VAR` resolution, first-write-wins claiming including the present-but-empty case, the 0600 context and its removal, the registry and snapshot writers, the shadows, ten testable invariants, and `_cloudify_registry_context_raw` (`lib/registry.sh:260-278`) as the second-walk defect to remove.
- Plan Technical review returned FAIL and every finding was fixed: the per-phase E2E gate now names a real artifact `tests/e2e/two-host-application.bats` with scenarios unlocked per phase; `tests/unit/drivers/{context,state,event,runbook}.bats` named as the L1 suite with `fixture-split` as the L2/L3 package; Phase 4.3 now names the parent dispatch epilogue as the new owner of context cleanup before the old remover is deleted, and names the golden-fixtures split so the payload matrix survives; Phases 4 to 8 each gained an explicit CRITICAL GATE subsection; the R3 schema-tightening task moved to Phase 4.1 because R3 writes no code; reviewers must now return a file:line evidence checklist alongside `PASS`, since a bare `PASS` is not a `PASS`; and R2.2 now deletes `lib/state.sh`'s hand-rolled JSON encoder and parser so one jq encoder is true repo-wide.
- CRITICAL GATE step 2 for R1 is done: `plans/state-model-v2-phase2-non-breakage.md` states the scope (`lib/context.sh` write block, `lib/registry.sh` re-opener deletion, `lib/vars.sh` raw-text capture at the single export decision), why forwarding cannot break for each of the ten description invariants with the code and the byte-exact test that re-asserts it, the one new risk (resolved plaintext in the 0600 ephemeral context) with its three mitigations, what was actually traced rather than assumed, and a falsification order that stops the slice on first failure. Consent from Rachid is the remaining step and has not been given.
- Plan Technical review round two returned FAIL with two findings, both fixed. The description artifact presented the current metadata-only context as a permanent invariant, contradicting `REDESIGN.md:302`; the artifact now carries a status and authority note, marks the metadata-only context and the frozen allow-list as superseded by design, and any later phase gate may supersede rather than only append. And `event.bats` was scheduled as an R1/R2 driver for a writer that only lands in Phase 4.1, which would have been an empty green file; the L1 drivers now land one per slice (context in R1, state and runbook in R2, event in 4.1, run record in Phase 6).
- Plan Technical review round three returned FAIL with three findings, all verified against the real code and fixed. (1) R1's scope omitted `lib/remote.sh:_cloudify_dispatch_vars`, whose allow-list extraction at `lib/remote.sh:127` is a `sed` over the flat context; once the context is JSON it matches nothing, the allow-list empties and payload forwarding silently stops exporting package values. Also omitted was the snapshot resolver in `lib/runbooks.sh` that still re-reads stores. Both are now in R1 scope with the payload template, the envsubst call and the stdin transport explicitly excluded. (2) The non-breakage argument claimed the context is "removed exactly once by the parent", which the code contradicts: `_cloudify_registry_record_bg` returns early without removing when `CLOUDIFY_DEPLOYMENT` is unset (`lib/registry.sh:395-397`), which is the direct package command path, and the `cleanup()` backstop returns early under `CLOUDIFY_LOG_LEVEL=DEBUG` (`lib/utils.sh:77-79`). Since R1 is the slice that first puts resolved plaintext in the file, the single-owner EXIT and RETURN trap plus the no-context-survives test moved from Phase 4.3 into R1. (3) Two citations were wrong: the claim call is `lib/vars.sh:169`, not `:172`, and the present-but-empty behaviour comes from `_cloudify_load_yaml_vars` keeping `KEY:` lines (`lib/vars.sh:200-224`), not from a check inside `_cloudify_vars_emit`.
- Plan Technical review round four returned FAIL with three findings, all verified against HEAD and fixed. (1) Two more flat-context readers would silently break under JSON: `cloudify_context_read` (`lib/context.sh:364-376`) does exact-key flat matching and is called by the DEBUG loop (`lib/remote.sh:250-260`), so DEBUG would have misreported `source=recipe secret=false` for every name and misrendered redaction. Both are now in R1 scope. (2) The "EXIT and RETURN trap armed at context creation" design was not implementable: a RETURN trap in `_cloudify_context_file_init` (`lib/remote.sh:94`) fires as soon as that function returns, before the backgrounded child fills the file, and is keyed to the single `CLOUDIFY_CONTEXT_FILE` while `_CLOUDIFY_BG_CONTEXT` holds one path per dispatch. Replaced with the flat two-layer design: the wait loop removes each dispatch's context unconditionally on the success path too, mirroring the failure path at `cloudify:821-824`, and one process-level EXIT trap in `main()` iterates `_CLOUDIFY_BG_CONTEXT[*]` without the DEBUG guard that neuters `cleanup()` (`lib/utils.sh:77-79`). (3) Citation drift corrected: the allow-list sed is `lib/remote.sh:123`, `_cloudify_dispatch_vars` spans `:106-134`, and the unreachable registry `rm` is `lib/registry.sh:418`.
- Plan Technical review round five returned FAIL with three findings, all verified and fixed. (1) The authority order listed the superseded attempt-1 artifacts (`plans/state-model-v2-description.md`, whose text still describes the deleted `_cloudify_pkg_remote_vars`) instead of the live R1.0 artifacts; items 6 and 7 now name `plans/state-model-v2-forwarding-description.md` and `plans/state-model-v2-phase2-non-breakage.md`, and the attempt-1 pair joined the evidence-only tier. (2) The prescribed process-level EXIT trap was not implementable: `_CLOUDIFY_BG_CONTEXT` is `local -A` in `main()` (`cloudify:412`) so an EXIT trap runs after `main()` returns and sees an empty array, and arming a second EXIT trap would replace `trap cleanup SIGINT SIGTERM ERR EXIT` (`cloudify:98`) and silently disable `CLOUDIFY_TMP` cleanup. Replaced with a flat design that reuses the existing trap: declare the array at global scope and put the removal loop at the top of `cleanup()` (`lib/utils.sh:74-87`) before its DEBUG early-return. (3) The description artifact's "must NOT touch" router clause contradicted its own re-assert list and R1.2; the wait-loop success-path removal and the global-scope declaration are now explicitly in scope.
- Plan review closed by Rachid's call: technical reviews cannot be open-ended. Plan-level review stops now, after five rounds that fixed eighteen verified findings and after three rounds that each surfaced only narrower items. A bounded-review rule is in the plan: stop after two consecutive rounds with no must-fix finding, log anything smaller as an implementation checklist, and let the phase gate settle it on real code. The five remaining verified-but-unfixed items are recorded in the plan as "Known implementation risks carried into R1" (four silent flat-context readers once the context is JSON, two live context-removal leaks, the golden-fixtures split, the `lib/state.sh` second JSON parser, and the missing two-host E2E artifact). From here the per-phase Technical review on a real diff is the primary gate.
- Rachid challenged the plan proliferation. Root cause: the SDLC rule (AGENTS.md) is one live plan via `PLAN.md` with done plans in `plans/archived/`, and two superseded attempt-1 artifacts (`state-model-v2-description.md`, `state-model-v2-non-breakage.md`) had been left live instead of archived. Both moved to `plans/archived/` with their references repointed. Remaining live in `plans/` is the one plan plus gate artifacts, which the project CRITICAL GATE requires as standalone reviewable written artifacts (the repo already does this for the errexit workstream, whose description artifact `ADR.md` cites).
- Rachid set the plan rule: ONE plan, full stop. `plans/state-model-v2-recovery.md` is the working plan via `PLAN.md`; if something in it does not fly, stop and raise it rather than forking a second plan; temporary artifacts including gate descriptions and non-breakage arguments live in the gitignored `tmp/`; only superseded plans go to `plans/archived/`. Since `tmp/` is gitignored, the durable trace of every gate artifact is recorded here in `LOGS.md`. Both R1 gate artifacts moved to `tmp/`, the plan gained a "One plan, and where everything else goes" section, and the authority order was simplified to AGENTS.md, ADR, REDESIGN, GLOSSARY, schemas, the plan, then evidence only. `plans/` now holds the one plan plus `errexit-restore-description.md`, which belongs to the earlier errexit workstream and is cited by `ADR.md:163`, so it was left in place pending Rachid's call rather than silently orphaned.
