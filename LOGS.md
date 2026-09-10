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
