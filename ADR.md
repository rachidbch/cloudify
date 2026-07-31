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
