# Cloudify — Architecture Decision Records

Concluded decisions only. Each: Status / Context / Decision / Consequences.
Never edit a past body; supersede via a new ADR. One-liner per decision lives in HISTORY.md with its ADR ref.

---

## ADR-001: Shadow command system for transparent injection

**Status:** Accepted
**Context:** Package recipes (init.sh) run on remote hosts over SSH and need sudo (passwords), apt-get (idempotency), git (auth), add-apt-repository. Forcing every recipe to plumb credentials/idempotency into every call would bloat all 75+ recipes and couple them to the credential store.
**Decision:** Recipes call bare commands (`sudo`, `apt-get`, `git`, `add-apt-repository`). A shadow layer (`lib/shadows/*.sh`, each guarded by `_CLOUDIFY_*_LOADED`) intercepts these via PATH ordering and injects passwords, dedupes installs, handles auth — transparently. Recipes stay clean and declarative.
**Consequences:** Recipes are portable and short. The shadow layer is load-bearing core; a broken shadow breaks every package. Shadows must stay idempotent (verified by apt-get cache pre-pass, HISTORY 2026-06-20).

## ADR-002: Per-package config — repo declares names, user provides values

**Status:** Accepted (superseded in part by ADR-006)
**Context:** Packages need per-deployment values (API keys, ports, emails). Early design hardcoded exports in `lib/remote.sh` core (HISTORY 2026-06-12 "Refactor remote var forwarding"), forcing a core edit per new var. Did not scale.
**Decision:** Split interface from value. Repo-side file declares which vars a package needs; user-side `~/.config/cloudify/pkgs/<pkg>.yaml` holds the values. `_cloudify_pkg_remote_vars` (lib/remote.sh) reads names + values, builds the envsubst allow-list dynamically. First-write-wins priority resolves conflicts across deps.
**Consequences:** Adding a package no longer touches core. But one file keyed by package name holds one value — parallel multi-deployment of the same package races (the gap ADR-006 closes). Secrets land on disk (acceptable for MVP; vault model deferred, ADR-007).

## ADR-003: Install guards — FORCE / CLEAR_DATA convention

**Status:** Accepted
**Context:** Stateful packages (docker, mariadb, fzf, wezterm...) re-running init.sh would reinstall or wipe data. 16 packages had ad-hoc skip checks of varying shapes (HISTORY 2026-05-19 "Document and apply install guard convention").
**Decision:** One convention. `CLOUDIFY_FORCE` set for explicit dispatches; `CLOUDIFY_CLEAR_DATA` (implies FORCE) wipes persistent data. Recipes place a single guard block after `pkg_depends`: skip if already-installed AND no force/clear. Thin packages (bat, jq) need no guard.
**Consequences:** Idempotent re-runs are safe by default; explicit reinstall and data-wipe are intentional acts. `pkg_depends` unsets both before sourcing dependency recipes (subshell isolation) so a parent's force never cascades into reinstalling deps.

## ADR-004: Verification hook — separate verify.sh, clean subshell, deep verify

**Status:** Accepted
**Context:** `cloudify install` returned before the service was actually up; operators had to `ssh`/`curl` manually after every install (HISTORY 2026-06-14, Issue #2).
**Decision:** Optional `pkg/<name>/verify.sh` defining `pkg_verify()`, sourced in a clean subshell by `_cloudify_run_verify` (retry loop, `${PKG_VERIFY_TIMEOUT:-30}s`). Deep verify runs after every package including deps. `--verify` (verify-only) / `--no-verify` (skip) / `cloudify verify` subcommand. Per-host failure reporting; exit non-zero if any host fails.
**Consequences:** Install blocks until healthy or fails clearly. Authoring contract enforced: verify reads env or on-disk config, never recipe-local vars or hardcoded endpoints (constraint a/b). Moved hermes-openwebui health checks from non-fatal `log_warn` to fatal verify — behavior change, intentional.

## ADR-005: Separate-containers topology for multi-service hosts

**Status:** Accepted
**Context:** One container running hermes + dashboard + open-webui hit routing limits: path-based tailscale serve breaks SPAs (absolute `/api/*`), subdomain certs unavailable (tailscale#7081), central Caddy can't get certs for other machines' FQDNs (HISTORY 2026-06-11).
**Decision:** One service per container. Each container gets its own MagicDNS hostname + root HTTPS + auto-TLS. Hyphenated names (`openwebui-hermes`) are first-class machine identities, not subdomains. No central Caddy for MagicDNS routing.
**Consequences:** Cleaner isolation, zero infra changes per service. More containers (resource cost). Inter-container reachability goes through Tailscale VIP services with `svc:` grants (the pattern proven in Hermes Unified Services, HISTORY 2026-06-13).

## ADR-006: Node-keyed state registry under ivps (k3s-driven)

**Status:** Accepted (to implement)
**Context:** k3s needs parallel multi-cluster: many deployments of the same package (k3s-server, k3s-agent) with different secrets simultaneously. ADR-002's single `~/.config/cloudify/pkgs/<pkg>.yaml` is keyed by package name → one value per package → parallel races, silent wrong-token joins. A cloud solution that accepts one deployment of anything is broken by design.
**Decision:** ivps owns node identity and is the registry of deployments-on-node. Tree: `~/.config/ivps/nodes/<node>/pkgs/<pkg>/deployments/<id>/config.yaml` (MVP `<id>` = default; the deployments level avoids an artificial one-pkg-per-node constraint). Opacity contract: `ivps node path <name>` prints the dir; cloudify writes `pkgs/<pkg>/...` there; ivps never parses pkg contents; `ivps delete <node>` nukes the dir so deployments die with the node. cloudify → ivps is a hard dependency; ivps stays clean of cloudify.
**Consequences:** Parallel multi-deployment works — values keyed by (node, pkg, deployment). Secrets land in ivps's tree (already a secret store via config.env; no new trust boundary). Cloudify's old `~/.config/cloudify/pkgs/` is retired (back-compat read during migration). Supersedes ADR-002's storage location; ADR-002's names-vs-values split holds.

## ADR-007: Per-package .remote-vars — names in repo, values from caller env

**Status:** Accepted (to implement)
**Context:** ADR-002 reads values from disk. The registry (ADR-006) stores state, but the *forwarding* path at install time must take values from the caller's environment so two parallel subshells each exporting their own token both forward correctly. Existing global `remote-vars.yaml` (remote.sh:124) is one shared file → same race.
**Decision:** `pkg/<name>/.remote-vars` declares var names (repo, static, version-controlled). `_try_claim` (remote.sh:103) gains: a name in `.remote-vars` takes its value from caller env (`"${!key}"`), not disk; warn if a declared name is unset so a missing value surfaces rather than forwarding empty.
**Consequences:** Names are a package property (repo); values are a deployment property (caller). Parallel-safe by construction. Pairs with ADR-006: cloudify persists caller env into the node registry at install time, so reuse across a cluster's nodes reads from registry, not re-entry. Existing per-pkg values-yaml stays for back-compat.

## ADR-008: install/run separation — configure verb, init.sh back-compat

**Status:** Accepted (to implement)
**Context:** init.sh conflates installing bits (idempotent, no secrets) with running a service (systemd unit, secrets, cluster membership). Verified in hermes-openwebui (apt install + systemctl in one file) and docker. The conflation blocks cheap secret rotation: re-running for a new token trips the install guard and bails or force-reinstalls the binary.
**Decision:** Optional split: `install.sh` (idempotent bits + install guard) and `configure.sh` (no install guard; rewrite unit, restart, resolve secrets). Backward compatible: if neither exists, `init.sh` runs as today. `cloudify install <pkg>` = install + configure for split pkgs. New `cloudify configure <pkg>` = run-phase only (cheap restart, secret rotation). k3s is the first split package and validates the design.
**Consequences:** Secret rotation and config change become cheap ops without binary re-fetch. The split earns its place when a package has a real run-phase concern (k3s token rotation). No forced migration; existing pkgs keep working until they want the benefit.

## ADR-009: k3s isolation via per-cluster tailnet tags

**Status:** Accepted (to implement)
**Context:** k3s inter-node traffic is a mesh (UDP 8472 VXLAN, TCP 10250/6443 — all-to-all per docs.k3s.io). The tailnet ACL has no container-to-container reachability except via VIP services (verified live on komodo-everest.ts.net; ROADBLOCK.md 2026-06-22). Multi-cluster needs both token isolation (free, k3s-enforced) and network isolation (ACL's job).
**Decision:** Per-cluster tag derived from cluster name: `tag:k3s-<cluster>`. ACL grant scoped to itself (`tag:k3s-prod -> tag:k3s-prod:*`) + `tag:workstation -> tag:k3s-<cluster>:*`. A tagged authkey (minted per cluster) routes nodes into their tag. ivps deltas: `tag create/delete/list`, `launch --tag` (strictly additive — no tag = today's `tag:incus` path).
**Consequences:** Clusters are network-invisible to each other regardless of tokens. Isolation is named and automatic. Tag lifecycle managed by ivps; cloudify stays cluster-unaware (the tag is the cluster identity, held by ivps).

---

## ADR-010: k3s spike outcomes (Phase 0 GREEN)

**Status:** Accepted
**Context:** The Phase 0 spike (2026-07-31) ran the k3s multi-cluster design against the live tailnet — 2 throwaway incus nodes registered as `tag:k3s-spike`, k3s v1.33.3+k3s1 server + agent. The cluster reached both-nodes-Ready with working cross-node pod traffic (ping 3/3, 8MB TCP in 3s). After teardown the ACL was restored to its pristine state (incl. comments), nodes deleted, authkey revoked. This ADR records the corrections and recipe requirements the spike forced; it supersedes the grant-syntax and operator-reach wording of ADR-009 (whose per-cluster-tag isolation intent holds — validated green). Item 1 was further corrected post-spike (atomic create) after the ivps agent's independent probe — see item 1 text.
**Decision:**
1. **`ivps tag create` is atomic (one POST), not a 3-phase lifecycle.** A grant referencing a tag resolves against `tagOwners` alone — **no node needs to carry the tag** (verified non-mutating via `/acl/validate` 2026-07-31: a host-only grant on a tagOwners-declared, node-less tag returns `{}`). One POST carries tagOwners + ssh.dst + grants. *(Correction of an earlier draft of this item: the spike's 400 "tag not found" was the port-wildcard grants syntax `tag:X:*`, then misattributed to "tag not on a node yet" — wrong. The ivps agent's independent live probe caught it; re-verified independently here.)*
2. **`grants` dst is host-only; ports go in the `ip` field.** `dst:["tag:k3s-spike:*"]` is invalid in grants (the misleading "tag not found" is really "port wildcard not allowed in grants.dst"). Correct: `{"src":["tag:k3s-spike"],"dst":["tag:k3s-spike"],"ip":["*"]}`. Legacy `acls` uses the `tag:X:*` form (port in the dst string); the two sections differ. Corrects ADR-009/F1.
3. **Operator-reach grant src is `autogroup:member`, not `tag:workstation`.** The live tailnet authorizes operator reach via `autogroup:member` (matches the existing hermes grants). Corrects ADR-009 wording.
4. **k3s recipe MUST set `--flannel-iface=tailscale0`.** Without it flannel's VXLAN VTEP defaults to the default-route interface (the incus bridge 10.47.x), not the tailscale 100.x — cross-node pod traffic shows 100% loss. `--node-ip`/`--node-external-ip` alone are insufficient (they do not move the VTEP). With the flag, pod ping + 8MB TCP succeed.
5. **k3s recipe MUST set `--kubelet-arg=feature-gates=KubeletInUserNamespace=true` (server + agent) in unprivileged incus.** Otherwise the kubelet crashes on `open /dev/kmsg: no such file or directory` (user namespace).
6. **MTU 1230 is optional hardening, not a requirement.** Path PMTU is 1280 (confirmed via `ping -M do`); flannel's default inner MTU is 1450. An 8MB TCP pod-to-pod transfer completes in 3s at the default — PMTUD absorbs the mismatch. Set 1230 defensively in the recipe, but it is not a gate.
7. **ACL `If-Match` is opt-in but enforced; validate is reliable if you read the body.** Omitting `If-Match` = unconditional write (200); a garbage etag = 412. The etag must be captured via GET-with-`-D` (HEAD / `-sSI` returns empty — that silently produced an unconditional write). `/acl/validate`: HTTP 200 + empty body `{}` = will POST clean; HTTP 200 + message body = will POST-fail (400).
**Consequences:** Phase 3 k3s recipes carry `--flannel-iface=tailscale0` + the `KubeletInUserNamespace` feature gate + (optional) flannel MTU 1230. F1 implements the 3-phase tag lifecycle idempotently (declare is a no-op if the tag exists; grants are safe because nodes register under the tag in F2 before any cluster uses them). The `cloudify-hermes` skill's ACL block had a latent `jq`-on-huJSON bug (jq cannot parse the `//` comments) — fixed 2026-07-31 to GET strict-JSON. Supersedes ADR-009's grant-syntax and operator-reach wording; ADR-009's isolation intent is validated.

## ADR-011: Deployments are applications — cloudify-owned, deployment-first state shape

**Status:** Accepted (to implement)
**Context:** Two prior threads converge. First, the node-keyed registry (ADR-006) keyed state as `nodes/<node>/pkgs/<pkg>/deployments/<id>/config.yaml` — packages-first, answering "what landed on this node". Second, the k3s cluster choreography needs a state layer for a unit that spans nodes (a cluster is more than one node's inventory). A deployment is the missing first-class unit: an application, distributed across nodes or not. A k3s cluster is an application and therefore a deployment. The packages-first shape asks the wrong question ("inventory") and scopes the deployment id inside (node, pkg), which forbids the real use case: one application spanning many nodes.
**Decision:**
1. A deployment is a first-class, cloud-global entity: an application composed of interrelated packages across nodes. A k3s cluster is a deployment (first tenant). Deployment ids are globally unique on the cloud; membership is derived by scanning node trees — there is no central index file (a shared index would reintroduce the parallel-write race).
2. Ownership split: cloudify owns applications (deployments). ivps owns resources (nodes, tags, network) and stays opaque to deployments, as it is to pkg contents. Cloudify delegates resource work to ivps (launch tagged nodes) but the application lifecycle is cloudify's.
3. State shape, deployment-first: per-node slices at `~/.config/ivps/nodes/<node>/deployments/<id>/pkgs/<pkg>/config.yaml` (supersedes ADR-006's `pkgs/<pkg>/deployments/<id>` ordering; the node level, `node path`, and the opacity contract hold unchanged, and the ivps side is shape-agnostic — only cloudify writes inside). Deployment-wide state at `~/.config/cloudify/deployments/<id>/` — a fixed-path convention, cloudify-owned, no ivps command needed, ivps never looks. `ivps delete <node>` nukes only the node's slices; deployment-wide state outlives nodes (cluster identity is durable) and dies only via `cloudify deployment delete <id>`, which never touches nodes. Teardown is three explicit acts: delete deployment, delete nodes, delete tag.
4. Current-deployment context is a per-shell env var (`CLOUDIFY_DEPLOYMENT`). No open/close commands, no shared context file (a shared file holding "which deployment am I in" races between concurrent shells — same class as the secrets file ADR-007 eliminated). `unset` is the close.
5. Command surface: `cloudify vars set/delete/list` (deployment-wide store; `--stdin`/`--file` for secret values so they never hit shell history) and `cloudify deployment list/delete`.
6. Value precedence, "closer to the machine wins": caller env at command time > per-(node, pkg) config (the record of what landed + node-specific values) > deployment-wide store.
7. Secrets are config: persisted in the deployment store and per-node config, plaintext for MVP under the existing `~/.config` trust boundary. Security model + a secrets backend (Secrets V2 plugin architecture) are a tracked follow-on, not this decision.
8. Payload debug masking must extend to `TOKEN`/`KEY` (today only `PWD`/`PASSWORD`/`SECRET` — `K3S_TOKEN` would print in cleartext in a DEBUG payload dump).
**Consequences:** The deployment registry is the state layer for application choreography; the k3s cluster's "dance" collapses into "a deployment" (open by env, install, rotate via `vars set` + configure). Deployment-wide state is buildable immediately — it needs zero ivps work; per-node slices wait on the node-registry branch (ivps PR #14) and the install-side registry write. The ivps-side work (node-as-dir, `node path`) is unaffected by the shape change. Open follow-ons: cluster-create flow shape (skill SOP vs a future cloudify flow verb), secrets backend design, per-deployment audit/review UX.

## ADR-012: CLOUDIFY_GITHUB_READONLY_TOKEN — canonical read-only clone credential

**Status:** Accepted
**Context:** GitHub removed password authentication for Git operations in 2021, but the cloudify git shadow authenticated clones with `CLOUDIFY_GITHUBPWD` (a password slot) — private clones (e.g. affine) failed with "Invalid username or token". Clone-time auth needs a token, and a fine-grained read-only PAT is a different secret class than the password slot.
**Decision:** New credential `CLOUDIFY_GITHUB_READONLY_TOKEN` (fine-grained PAT, Contents: read-only) is the canonical credential for clones. Wired at every hop (or it is inert): the credentials section (ask/save/status — the token alone satisfies the github check), the remote payload export + envsubst allow-list, and the git shadow, which prefers it over `CLOUDIFY_GITHUBPWD` (`GIT_TOKEN="${CLOUDIFY_GITHUB_READONLY_TOKEN:-${CLOUDIFY_GITHUBPWD:-}}"`). Purely additive: empty var → previous behavior.
**Consequences:** Private-repo clones authenticate with a least-privilege token instead of a password. The status check no longer requires user+password when the token is set. Existing setups with only the password slot keep working unchanged. README "Credentials" documents it.

## ADR-013: dsh remote-settings gate — accessor-based plugin pin (dsh-loopback-pin)

**Status:** Accepted
**Context:** Remote browsers (tailnet) hit two dsh gates: the `/api` loopback fence and a client gate where the settings UI refuses to load unless `connection.isLoopback` is true (the settings mirror then picks 'memory' persistence). dsh-full-remote solves the fence via an authenticated loopback proxy; its client gate relies on a page-bootstrap that wraps `loader.load` once. Live diagnosis (2026-08-20) proved the shipped runtime reassigns `loader.load` to a thin `registration => this.register(registration)` arrow after the wrap, clobbering it silently — the marker (`__dshFullRemoteTrusted`) survives, the wrapper does not, so the pin never runs.
**Decision:** Ship our own plugin, `dsh-loopback-pin`, inside the deepseek-harness package. It installs an accessor on `loader.load` (getter always returns the intercepting function; setter captures reassignments as the new delegate) and wraps the connection module's factory to pin `connection.isLoopback = true` on the handle right after its apply — the settings plugin injects connection, so Cordis orders it after. Replaces the sed patch on the served bundle (removed; bundle stays pristine). Version-drift resistance comes from the accessor re-wrapping whatever loader/load rc.N ships.
**Consequences:** Settings → Models works from remote browsers with a pristine bundle, verified live end-to-end (console markers + provider directory renders). Recipe copies the plugin to `/opt/dsh-loopback-pin` and registers it via `dsh plugin --profile web add` (local path); re-running install after a dsh bump re-applies it. Third-party dsh-full-remote still owns auth + fence; our plugin is ~90 lines, no deps, and inert if the connection module ever stops loading that way (console-warn only).
