# Plan: k3s multi-cluster provisioning on the cloudify/ivps private cloud

> Design + grounding: `scratchpad/ivps-cloudify-evolutions-proposal.md`
> Decisions: `ADR-006`–`ADR-011`. Issue tracker: GitHub (links in `## Issues`).
> ROADMAP entries: k3s multi-cluster, k3s HA, k3s Tailscale CNI.

## Goal

Spin up isolated k3s clusters with a few lines of ivps + cloudify. Each cluster
network-isolated from every other via a per-cluster tailnet tag. k3s is the
trigger and first consumer of three deeper changes: a node-keyed state registry,
install/run separation, and parallel-safe env forwarding.

## Working discipline (applies to every code task below)

- **TDD.** Red ONE bats spec → min green → refactor → next. Bug fixes reproduce E2E first.
- **Testing Trophy.** Prioritize integration/E2E; unit only where logic earns it.
- **Container SDLC (cloudify).** `task setup-container` (one-time), `task test-unit`, `task test`, `task lint`. **Push before tests** — integration tests SSH into `cloudai:cloudify`, pull from GitHub, run there.
- **ivps tasks are delegated** to the ivps agent under ivps's own SDLC/bats. Read ivps CLAUDE.md/HISTORY before delegating; the plan names the acceptance, not the ivps-internal mechanics.
- **Per-phase gate.** A phase is done when all its `[x]` are checked AND `task test` (or ivps equiv) is green AND HISTORY + the issue are updated. No forward motion with a red gate.
- **One issue per task.** Each `[ ]` below carries an issue ref; close the issue when the checkbox flips.

## Decisions (recorded in ADR-006–ADR-010)

1. Per-cluster isolation via per-cluster tag `tag:k3s-<cluster>` + scoped ACL mesh. Token differs per cluster too (k3s-enforced).
2. State shape superseded by ADR-011: deployments-first (`nodes/<node>/deployments/<id>/pkgs/<pkg>/config.yaml`) + deployment-wide store (`~/.config/cloudify/deployments/<id>/`). Deployment = application (a k3s cluster is one); cloudify owns applications, ivps owns resources. ADR-006's node level (`node path`, opacity) holds unchanged.
3. Opacity contract: `ivps node path` prints the dir; cloudify writes `pkgs/...`; ivps never parses pkg contents; `ivps delete` nukes the dir.
4. cloudify → ivps hard dependency (ivps = node registry). ivps stays clean of cloudify.
5. install/run split, backward compatible (`init.sh` runs as today if no split). `cloudify configure` = run-phase only.
6. k3s is the first split pkg (validates the split).
7. Secrets V2 = plugin architecture, default plaintext. Out of scope for MVP.
8. MVP CNI = flannel VXLAN over tailscale0 (MTU 1230 optional per spike).

## Phase 0 — Spike ✅ DONE 2026-07-31 (GREEN; see ADR-010)

2 throwaway incus nodes `tag:k3s-spike`, k3s v1.33.3+k3s1 server + agent. Both
nodes Ready; cross-node pod ping + 8MB TCP OK. ACL restored pristine, nodes
deleted, authkey revoked. Recipe deltas folded into Phase 3.

- [x] Mesh hypothesis (ADR-009): TCP 6443 reachable across tag mesh; agent joins.
- [x] ACL lifecycle: `tag create` is ATOMIC (one POST: tagOwners + ssh.dst + grants); a grant resolves against tagOwners alone, no node needed (the earlier "3-phase" was a misdiagnosis; spike 400 was port-wildcard grants syntax — re-verified via /acl/validate).
- [x] Grants syntax: dst host-only + ports in `ip` (not `tag:X:*`); operator src `autogroup:member`.
- [x] Recipe flags: `--flannel-iface=tailscale0` + `KubeletInUserNamespace` both REQUIRED.
- [x] MTU 1230 demoted to optional (default 1450 transfers 8MB TCP in 3s).
- [x] hermes skill `jq`-on-huJSON bug fixed (GET `Accept: application/json`).

## Phase 1 — ivps deltas ✅ DONE 2026-08-07 (ivps main: aa11968)

All merged to ivps main. F1 (tag create/delete/list, #12), F2 (launch --tag, #13),
F3 (node-as-dir + node path, #14), and the ACL surface (acl show/grant/revoke/rollback,
#15, locked+snapshotted+re-derived writes).

Separation (2026-08-06 boundary decision): `tag create/delete` = identity only
(tagOwners + join authkey). Grants/ssh.dst moved to `ivps acl grant/revoke`;
operator src is caller-provided (tag:workstation, tag:mobile), never hardcoded
autogroup:member. ACL write path shared by acl+tag: exclusive flock, snapshot
before write, 412-retry re-derives from fresh fetch. Live e2e green.

- [x] **F1 `ivps tag create/delete/list`** [#9] — merged (1449402). Identity only;
  grants separated to acl per boundary decision.
- [x] **F2 `ivps launch --tag`** [#10] — merged (a4f48d9). Strictly additive;
  no-tag = today's tag:incus argv byte-identical.
- [x] **F3 node-as-dir + `ivps node path`** [#11] — merged (f2ce76c). Unblocks C3.
- [x] **ACL surface** [#15] — merged (874f9ac). grant/revoke/rollback/show;
  locked writes, snapshots, 412 re-derive.

Retracted (do NOT build): "launch blocks until SSH-ready" — shipped 2026-06-14.

## Phase 2 — cloudify deltas (self; cloudify SDLC)

- [x] **C1 `.remote-vars`** [#5](https://github.com/rachidbch/cloudify/issues/5) — TDD. Red spec: parallel two-cluster fixture
  (each subshell exports own `K3S_TOKEN`) asserts each host received its own value
  (the regression that would re-appear if a shared file crept back). Impl in
  `_try_claim` (remote.sh:103): name in `pkg/<name>/.remote-vars` → value from
  caller env (`"${!key}"`), warn if unset. Gate: `task test-unit` green, then
  `task test`. Back-compat: existing per-pkg yaml + global `remote-vars.yaml` stay.
- [x] **C2 install/run split** [#6](https://github.com/rachidbch/cloudify/issues/6) — TDD. Red spec: fixture split pkg
  (`install.sh` + `configure.sh`); assert `install` runs both, `configure` runs
  one and does NOT re-download/trip guard, init-only pkg unchanged. New
  `cloudify configure <pkg>` verb; errors clearly for non-split. verify-hook
  (ADR-004) runs after both. Gate: `task test`. **Blocks Phase 3** (k3s = first split pkg).
- [ ] **C3 state-registry write** [#7] — **blocked by F3 [#11].** TDD. Red spec
  round-trip: install writes per-node slice `$(ivps node path host)/deployments/<id>/pkgs/<pkg>/config.yaml`
  + deployment-wide values in `~/.config/cloudify/deployments/<id>/` (ADR-011);
  re-install without env reuses stored value; `ivps delete host` removes it. Retire
  `~/.config/cloudify/pkgs/` to read-only back-compat. Integration with C1:
  parallel two-cluster installs write their own node's registry, no cross-contamination.
  **Status (2026-08-06): reshaped by ADR-011. Split: (a) deployment-wide store +
  `cloudify vars` — UNBLOCKED; (b) per-node slices — blocked on F3 merge.**

## Phase 3 — k3s recipes (self; first split pkg; cloudify SDLC)

Recipe requirements spike-grounded (ADR-010): every node sets
`--flannel-iface=tailscale0` + `--kubelet-arg=feature-gates=KubeletInUserNamespace=true`;
node-prep = br_netfilter/overlay/ip_forward/swapoff; pin `--node-ip`/
`--node-external-ip` to tailscale 100.x; server `--tls-san` to its tailscale DNS
name. MTU 1230 optional (defensive).

- [ ] **k3s-server** [#8] — split pkg. install.sh (binary + airgap + node-prep +
  guard), configure.sh (systemd unit, single-server/`--cluster-init`, the two
  required flags, `--tls-san`, reads `K3S_TOKEN`), `.remote-vars` (`K3S_TOKEN`),
  verify.sh (`kubectl get nodes` shows server Ready). Red spec: install on a
  throwaway node → server node Ready at its tailscale IP (reproduces spike).
  **Status (2026-08-07): recipe written on feat/k3s-recipes (structural unit tests
  green). ivps acl unblocks e2e — acl grant calls added to e2e test. Ready to run.**
- [ ] **k3s-agent** [#8] — split pkg. install.sh (binary + node-prep),
  configure.sh (systemd unit, `K3S_URL`+`K3S_TOKEN`, the two required flags),
  `.remote-vars` (`K3S_TOKEN`, `K3S_URL`), verify.sh (server's `kubectl get nodes`
  shows this node Ready). Red spec: agent joins a server across the tag mesh,
  both nodes Ready (reproduces spike).
  **Status (2026-08-07): recipe written on feat/k3s-recipes; e2e unblocked.**
- [ ] **k3s-cli** [#8] — init.sh (kubectl + helm, fetch kubeconfig, rewrite
  `server:` to tailscale DNS name, merge as kubeconfig context per cluster).
  **Status (2026-08-07): recipe written on feat/k3s-recipes.**
- [x] **Two-cluster parallel UX validation** [#8] — E2E: two mutually-isolated
  clusters (own tag, own token; prod agents cannot reach dev nodes).
  `kubectl --context k3s-prod get nodes` + `... k3s-dev ...`.
  **Status (2026-08-10): VALIDATED GREEN twice — manual 7-step run (2026-08-09)
  plus the deployments-driven run (2026-08-10): token from the deployment store,
  no env var, 2 nodes Ready (proves ADR-011 end-to-end; see HISTORY).**
  **Token rotation DROPPED (user decision): k3s limitation — join token IS
  the etcd bootstrap encryption key, rotation fatal-fails. configure run-phase
  validation moves to a simpler split pkg (ROADMAP). Test 8 removed from e2e.**

Target UX (validated by the spike):
```bash
spawn_cluster() {
  local c=$1; shift; local agents=("$@")
  local tag="k3s-$c" server="k3s-${c}-1"
  local token; token=$(openssl rand -hex 16)
  ivps tag create "$tag"
  ivps launch cloudai:"$server" --tag "$tag"
  K3S_TOKEN="$token" cloudify --on "$server" install k3s-server
  for n in "${agents[@]}"; do ivps launch cloudai:"$n" --tag "$tag"; done
  for n in "${agents[@]}"; do
    K3S_TOKEN="$token" K3S_URL="https://$server.$(awk -F\" '/^TS_DOMAIN=/{print $2}' ~/.config/ivps/config.env):6443" \
      cloudify --on "$n" install k3s-agent
  done
}
spawn_cluster prod k3s-prod-2 k3s-prod-3 &
spawn_cluster dev  k3s-dev-2  k3s-dev-3  &
wait
cloudify install k3s-cli; kubectl --context k3s-prod get nodes
```

## Issues

- **ivps:** [#9 F1 tag create](https://github.com/rachidbch/ivps/issues/9) · [#10 F2 launch --tag](https://github.com/rachidbch/ivps/issues/10) · [#11 F3 node path](https://github.com/rachidbch/ivps/issues/11)
- **cloudify:** [#5 C1 .remote-vars](https://github.com/rachidbch/cloudify/issues/5) · [#6 C2 install/run split](https://github.com/rachidbch/cloudify/issues/6) · [#7 C3 registry write](https://github.com/rachidbch/cloudify/issues/7) · [#8 C4 k3s recipes](https://github.com/rachidbch/cloudify/issues/8)

## Dependencies / order

```
Phase 0 spike ──gate──► everything
Phase 1 F1[#9]+F2[#10] ─┐
                        ├─► (parallel) ──► Phase 3 k3s recipes [#8] ──► UX validation
Phase 2 C1[#5]          ─┤
Phase 1 F3[#11]         ─┴─► Phase 2 C3[#7] (registry write needs node path)
Phase 2 C2[#6]          ───► Phase 3 (k3s uses split)
```

C3 [#7] blocks on F3 [#11]. C2 [#6] blocks Phase 3 [#8]. F1/F2 and C1/C2 independent.

## Separable follow-up (not this plan)

- ~~`cloudify-hermes` SKILL.md: drop the stale launch-wait retry loop (ivps owns it since 2026-06-14). One-line skill edit.~~ DONE 2026-07-31. (ACL jq/hujson bug already fixed this session.)
