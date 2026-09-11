# Cloudify Roadmap

## URGENT - clean the surface before anything else (2026-09-07 E2E traps)

Policy: compose-ability. Fix at the root (CRITICAL GATE where lib/router touches code), then revisit the deployment-runbook section below.

1. `vars` sits outside `deployment` and needs ambient `CLOUDIFY_DEPLOYMENT`. Fix: explicit flag `cloudify vars set|show|list|delete <key> [<value>] --deployment <id>` (omitted = ambient). Standardize on the existing flag idiom.
2. Forwarding truth (corrected 2026-09-07, from lib/remote.sh): only the ENV path is declaration-gated; file stores (global file, machine values, deployment) forward unconditionally. So an undeclared env var is silently inert, and it cannot be warned at set time (env is a shared user namespace; cloudify never sees undeclared names). Mitigation = the pkg-writing standard below (declaration kept in sync with the recipe).
3. Stale postgres volume breaks DB auth. Resolution (decided 2026-09-07): NO defensive guard. Uninstall leg owns teardown (`compose down -v` BEFORE removing the project dir); configure leg converges the DB credential via the postgres local socket; compose semantics replace bash wait loops. Requires the framework uninstall action + a guacamole 3-leg rewrite.
4. `verify` is a local subcommand plus a flag alias, so remote verify-only needs `--verify install` and the symmetric form fails with a misleading "no packages found" error. Resolution (decided): make `verify` a first-class action in both contexts (`cloudify --on <host> verify <pkg>`), keep `--verify install` as the alias (extends ADR-004), and fix the parser error when trailing words are not packages.
5. Password handoff: xfce env-passed passwords are never printed; a glued deployment must carry them. Resolution (decided 2026-09-07): secrets are ordinary vars plus hygiene (`vars set --stdin`, masking, references in the state registry). The real gap is one value needing two names (xfce user password = guacamole RDP password). Now: documented convention (set both from one deployment value, as the E2E did); later: deployment var bindings (general derived-var feature, ROADMAP). ADR-017 covers standalone generate+print.
6. Human URLs use tailnet names (MagicDNS), never IPs; guacamole serves at root. Resolution (decided 2026-09-07): user-facing URLs and cross-host references use MagicDNS names; address-shaped values (the bind) are derived at run time from the host's own tailnet identity, never hardcoded; validate once that guacd resolves MagicDNS from inside the compose network; capture the rule in the cloudify skill.
7. Naming defaults: package defaults must be neutral or required; identity-specific values belong in config. Resolution (decided 2026-09-07): guacamole admin default `rbc` -> `guacadmin` (Guacamole's seeded name; no rename when unset). `gui`/`GUI` stay neutral. No skill item (common sense); the discovery fix is the reader command below.

### Vars CLI + declaration (decided 2026-09-07)

- Vars CLI, flag-scoped, mutually exclusive: `cloudify vars show|set|unset|list <key> [<value>] [--global | --pkg <name> | --deployment <id>]`; no flag = ambient `CLOUDIFY_DEPLOYMENT`, error with hint if unset.
- Repo declaration `pkg/<name>/.remote-vars` carries the pkg-writing standard; no drift-detection machinery, the cloudify skill carries the rule "edit recipe defaults and the repo declaration in sync".
- Pkg-writing standard for vars (decided 2026-09-07): required `NAME`; defaulted `NAME=value` (declaration mirrors the recipe default; the recipe's `${NAME:-value}` stays runtime truth, so local and remote installs behave the same); optional `NAME=` (empty = absent, silent). Declaring a name is what makes the env path forward it.
- Package lifecycle rule (extends ADR-008, decided 2026-09-07): install provisions (create-if-absent, never mutates existing config), configure configures (applies desired config, including convergence), uninstall tears down (down -v then remove the project dir). Needs a real `uninstall` action in the router (today a stub) + optional `uninstall.sh` per pkg with a defined default.
- Compose-semantics-first (pkg-authoring docs, decided 2026-09-07): express service behavior with compose (`healthcheck`, `depends_on: condition: service_healthy`, `restart`, `env_file`, `docker compose up -d --wait`), never bash wait loops or hand-rolled checks. Guacamole's install/config/uninstall legs are the reference rewrite (also evaluate mounting the schema under `/docker-entrypoint-initdb.d` instead of docker cp + psql).
- Reader command: `cloudify vars declared <pkg>` prints every consumed var with its kind, so the user sees the whole knob surface: `NAME` = required, `NAME=value` = defaulted (default shown), `NAME=` = optional (no default). Same three kinds as the pkg-writing standard; optionally append which source currently sets it (global/package/deployment/env).
- Revive the state registry (unblocked since ivps node-as-dir landed): the registry is OBSERVATION, not a plan: per (deployment, target, package) status, timestamps, version, and a value snapshot (reference if the source was one, else raw; 600; never git), at `$(ivps node path <node>)/deployments/<id>/pkgs/<pkg>/config.yaml` (add `<instance>/` for an instance target). Replay is separate: playable runbook (plan) + values (deployment store + run snapshot) = `deployment run` (converge) / `deployment replay` (reproduce); it never enters the precedence ladder (`cloudify_vars_state_read` dropped). Targets are named slots bound at run time to `node` or `node:instance` (`--on X` / `X:` / `X:Y` / `:Y`; active = per-shell `CLOUDIFY_NODE`, else the ivps default; no localhost fallback). Supersedes ADR-011 pts 3/6/7 - amend when implementing.

### Vars internals + security (decided 2026-09-07)

- Five-source naming refactor (URGENT): one read/write helper per source, one scheme - `cloudify_vars_{global,pkg,deployment,env}_read|write`, `cloudify_vars_state_read` (replay, read-only). The collector becomes a thin precedence walker over them, replacing `_try_claim`, `_try_claim_env`, `_cloudify_deployment_read_vars`.
- Vault integration, two supported models (a reference resolves at either end): operator-side (default; cloudify resolves and ships plaintext; hosts stay vault-free) and host-side (only the reference ships; host needs vault credentials + reachability). No vault configured -> the vault reader is never consulted (zero cost, zero pkg-dev work; the resolver has an identity default).
- Exposure inventory + rules: transit = SSH-encrypted; operator argv + config files hold plaintext in the operator-side model (host-side removes argv); host argv holds plaintext today -> harden by sending the payload via stdin, not argv; recipe state files 0600; cloudify's own config/state files hold references or hashes, never plaintext; software config files a recipe writes (compose .env) may hold secrets, 0600, unavoidable. Fundamental limit: the host must hold the plaintext; no vault removes that.
- Cloudify skill: add a Security section (stars: payload via stdin not argv; references in cloudify state; masking PASSWORD/TOKEN/SECRET/KEY; 0600; no secrets in logs; the two vault models + the fundamental limit).

### Target config model (record; implement with the forwarding model above)

REPO: R1 recipe `${VAR:-default}` (weakest value layer); R2 `pkg/<name>/.remote-vars` = declaration, names only (contract, not a value).
MACHINE, applied in order, last wins: M1 `~/.config/cloudify/remote-vars.yaml` global default; M2 `~/.config/cloudify/pkgs/<pkg>.yaml` package values; M3 `~/.config/cloudify/deployments/<id>/` application values; M4 caller env (strongest).
Today inverted: `remote-vars.yaml` is strongest (flip to global default); deployment vars are weakest (promote above package values).

### Runbooks (urgent; in order, after the trap cleanups)

a) Agent runbooks (docs, not code). Plain documents under a `runbooks/` tree in the cloudify repo, executed by an agent or human with ONLY ivps + cloudify commands. Tree = flavors: `runbooks/<app>/<flavor>.md`. Rules: no ad-hoc scripts; variable NAMES in steps, never values; addresses by MagicDNS name, never IP; explicit human-gate steps (render acceptance); explicit teardown steps. Validation = the amnesiac test: a fresh agent session given only the cloudify skill + the runbook path completes the deployment on disposable infra with no human hints; every stumble is a runbook defect. First candidate: rewrite plans/xfce-guacamole-e2e.md into runbooks/ under these rules.

b) Cloudify runbooks (`cloudify deployment run <id>`), after (a). Deployment declares targets + typed steps as data: launch, install, configure, verify, uninstall, human-gate. Addresses by name. Step outputs (e.g. the launched guest's tailnet name) live in the registry (deployment, target, package), never merged into intent config; later steps consume them live. Preflight validates required vars via `vars declared` before launching anything. Secrets referenced by name (five-source walker; optional vault on either end). Per-step security rules: payload via stdin, no secret in argv, masking. Build on the fixed surface only (trap cleanups first).

## Registry distribution (non-urgent)

**Problem:** the registry (deployment/target/package records) lives only on the operator host, so that host is a single point of failure for the records themselves - not just for concurrent writers. Losing the laptop loses the registry. Runbooks are safe (they live in git); the registry is not.

**Experiment:** replicate/publish registry events (NATS/JetStream or equivalent) so records survive an operator loss and several operators can read them. Open question: operator-local append + async replication vs a central broker as the write master. A backup/snapshot step is the cheap first move; replication second.

**Constraint:** the registry holds deployment values and generated outputs, so git is not a valid backup target (it would commit data that must not leave the host). Backups must be secret-aware and local/encrypted.

## IPv6 and the target `:` delimiter (non-urgent)

The `node:instance` target syntax splits on the first colon, which collides with IPv6 literals (`fd42::1`) and `host:port` shaped values. `--on` is name-based today so it does not bite yet, but the delimiter must become unambiguous before targets accept addresses. Options: a distinct separator, bracket-wrapping IPv6 (`[fd42::1]`), or a `--node`/`--instance` flag pair instead of a delimiter.

## Target inventory adapter (non-urgent)

Target resolution (is X a node? which node hosts instance X?) piggybacks on ivps inventory today. Put it behind a small adapter seam so cloudify can use ivps or another provisioning/inventory tool and keep its own registry root. Decide the adapter API (look up node/instance, list targets, provision) and whether cloudify's registry root is its own (`~/.config/cloudify/...`) or delegated to the provider.

## Runbook teardown phase (non-urgent)

The runbook engine runs steps in document order with no phase concept, so a teardown section
placed after a `human-gate` is reachable by a plain `cloudify deployment run <id> --yes`: it
auto-confirms the gate and then immediately tears the deployment down. The only guard today is
operator discipline (`--from <id>`), which lives nowhere in the artifact.

Fix: a `phase=main|teardown` step attribute (default `main`). `deployment run <id>` executes
`main` only; `deployment run <id> --phase teardown` (or a `cloudify deployment teardown <id>`
verb) executes the teardown phase in declared order with the same preflight/verification. Makes
the human gate the natural main/teardown boundary and removes the `--yes` footgun. Small
`lib/runbooks.sh` change + tests; runs the CRITICAL GATE. The teardown ORDER itself is
documented in `runbooks/README.md` ("Teardown contract").

## Remote bootstrap git pull vs task sync (non-urgent)

The test container gets code from two writers into the same `/root/cloudify`: the bootstrap gist (`git pull` from GitHub) and `task sync` (rsync from the laptop). When a synced file is not yet in the container's checked-out commit, git sees it as untracked and refuses the pull ("untracked working tree files would be overwritten"), so the pull aborts and the clone stays stale; runs still use the synced tree. Reproduced 2026-09-10 on `cloudai:cloudify` with `lib/targets.sh`. Fix direction: bootstrap resets to the remote (`git fetch && git reset --hard`) or cleans untracked files before pulling; a remote-bootstrap change (brittle core), own gate.

## Mixed local/remote host list dispatch (non-urgent)

`_cloudify_dispatch` picks local vs remote once for the whole run (only when the host list is exactly `localhost`). A list containing `localhost` plus a remote host (`--on localhost cloudai ...`, or a tag expanding to both) sends the whole run down the remote path; the `localhost` leg then receives the package text as one already-joined argument (`cloudify "verify bats-test"`) and dies `Unknown argument`. Reproduced 2026-09-10 with a read-only `verify`. Fix: decide per host, and carry packages as a list, not a string.

## apt dpkg lock race (non-urgent)

**What happened:** `cloudify uninstall xfce` failed with `E: Could not get lock /var/lib/dpkg/lock-frontend ... held by process (unattended-upgr)`; the recipe's `apt-get purge || die` turned a transient lock into a hard failure. The xfce uninstall leg now passes `-o DPkg::Lock::Timeout=300`, but the shadow `apt-get install`/`update` paths do not, so any install can hit the same race.

**Why:** Ubuntu runs `unattended-upgrades` on a timer and it holds the dpkg lock. The shadow apt-get runs `sudo apt-get -qq install`/`update` with no lock wait.

**Plausible fixes to study:** add `-o DPkg::Lock::Timeout=<n>` to the shadow's install/update calls (framework-wide, CRITICAL GATE); or a preflight that waits for the lock before any package action; or a package-api helper recipes must call. Trade-off: an unbounded wait can hide a genuinely stuck apt; prefer a bounded wait with a clear message.

## shadow sudo requires a password even as root (non-urgent)

**What happened:** `cloudify --on localhost uninstall xfce` from a shell without `CLOUDIFY_LOCAL_PWD` died silently; the shadow `sudo` calls `die "Password not set for user ... on host ..."`, and the message was lost in the remote tee, so the failure looked like a mid-recipe abort and cost diagnosis time.

**Why:** the shadow always injects a password via a herestring; it never tries `sudo -n` first. Running as root (or with a valid sudo timestamp) needs no password, so the requirement is artificial in that case. The failure is also silent.

**Plausible fixes to study:** try `command sudo -n "$@"` first and fall back to the password path; ensure the shadow's `die` message always reaches the log (flush/log before exit); otherwise document that `--on localhost` needs `CLOUDIFY_LOCAL_PWD`.

## bash usage spam during installs (non-urgent)

**What happened:** xfce/guacamole installs emit repeated `bash: - : invalid option` lines plus a full bash usage block, and `comm: file 2 is not in sorted order`; a fresh reader reads them as failures.

**Why:** some command invokes `bash -` (or with a bad flag), and a `comm` runs on unsorted input.

**Plausible fixes to study:** find the caller (likely a shadow or the verify hook) and fix the invocation; sort before `comm`.

## Node MagicDNS name command gap (non-urgent)

**What happened:** the amnesiac runbook needs the guest's full MagicDNS name (`<node>.<tailnet-domain>`) for cross-host references. `ivps status <remote:name>` prints the Tailscale IP only, `cloudify info` prints the LAN IP, and `cloudify exec <host> 'tailscale ip -4'` output carries the `host: ` prefix. The bare container name resolves to an Incus-internal address on the same node.

**Why:** no command returns a node's MagicDNS FQDN cleanly, so runbooks cannot derive it as the rules require (MagicDNS names, never IPs).

**Plausible fixes to study:** `ivps status`/`ivps info` gains a MagicDNS field (or `--json`); or `cloudify info <host> magicdns`.

## cloudify host/info subcommand gaps (non-urgent)

**What happened:** the cloudify skill documents `cloudify host <host>` and `cloudify info <host> [ipv4|ipv6]`. `cloudify host cloudify` fails with `Error: Unknown argument 'host'`; `cloudify info cloudify` (non-inventory host) fails with `lib/hosts.sh: line 97: $1: unbound variable`.

**Why:** the router has no `host` subcommand, and `cloudify_info` reads `$1` without a guard.

**Plausible fixes to study:** add the `host` subcommand or remove it from the skill; guard `cloudify_info` for a missing/unknown host with a clear error.

## Tag-to-tag tailnet reachability (non-urgent)

**What happened:** the runbook's guacamole host and guest are both `tag:incus`; Tailscale denies tag-to-tag by default, so the guest was unreachable until an explicit grant. The correct form is `ivps acl grant <guest> --src tag:incus --port 3389` (dst positional, `--src` required).

**Why:** the default ACL covers `autogroup:member` and `tag:node`, not `tag:incus` to `tag:incus`.

**Plausible fixes to study:** document the pattern in the ivps/runbook docs; or a runbook helper that derives and grants the required reachability.

## guacd MagicDNS resolution check (non-urgent)

**What happened:** the runbook sends the guest's MagicDNS name as the Guacamole RDP host, but nothing proves guacd resolves MagicDNS from inside its compose network except the human render gate.

**Plausible fixes to study:** a check (a compose healthcheck or a `verify.sh` step) that resolves the name from inside the guacd container.

## Resolution precedes every phase (non-urgent)

Today install/configure/uninstall resolve vars through the walker, and verify fills unset names from the package yaml (verify-only has no walker). Cleaner: make resolution a step that always precedes a phase, verify-only included, then remove the source read from verify. Effect: verify never re-reads a source, so there is no precedence question inside verify. Cost: verify-only would apply the full five-source ladder instead of the package yaml alone, and remote verify-only forwarding would need a decision. Not needed for the parent-override fix already shipped.

## Dependency garbage collection (non-urgent)

Uninstall removes only the named package; dependencies are never auto-removed (they may be shared). Future: scan the inventory and uninstall packages and dependencies no longer needed by anything. Inputs: the per-node state registry (what landed, keyed by deployment, instance, package) plus each recipe's `pkg_depends` graph. Output: a candidate list for explicit user consent, never an automatic purge. Depends on the state registry.

## Package discovery: one-liner descriptions in `cloudify packages`

`cloudify packages` lists package names only — no descriptions. To discover what a package does, users must read `pkg/<name>/init.sh` individually. Each init.sh already has a header comment (e.g. `# bat is better cat`).

**Proposed:** `cloudify packages` reads each init.sh header comment and displays a one-liner description column. Format options:
- `cloudify packages` — name + description (compact table)
- `cloudify packages show <pkg>` — full recipe (already exists)

Implementation: extract lines 2–3 from each init.sh (the `# description` pattern), strip `#` prefix. Non-invasive — no new files or convention changes needed.

## Error aggregation in `cloudify_install_package`

`cloudify_install_package()` in `lib/packages.sh` calls `pkg_depends "$pkg"` in a loop, one package at a time. With `set -e` active, the first failure aborts the entire function — remaining packages are never attempted, and no error report is printed.

This is inconsistent with the design principle that **error aggregation belongs at the orchestration level**. `pkg_depends` already collects errors within a single call, but `cloudify_install_package` doesn't benefit from it when installing multiple packages (e.g. `cloudify install foo bar baz`).

**Proposed fix**: Apply the same error-collection pattern — continue through failures, collect failed package names, report comprehensive list at end.

## Parity between local and remote logging

Remote execution (`cloudify install foo --on myhost`) captures all stdout/stderr in `$CLOUDIFY_LOG_FILE` via `tee -a`. Local execution (`cloudify install foo`) only logs `msg`/`log_*` calls — bare `echo`, command output, and subcommand errors from package recipes are lost.

**Proposed fix**: Tee local package execution to the log file the same way `cloudify_remote_sync` does for localhost (remote.sh:74). This ensures local installs produce the same complete log as remote ones.

## Audit package recipes for proper logging

Many packages use bare `echo` instead of `msg`/`log_*` functions, so their output is not captured in `$CLOUDIFY_LOG_FILE` and has inconsistent formatting. Example: `pkg/hermes/init.sh` uses no `msg` or `log_*` calls at all.

**Proposed fix**: Review all package recipes (`pkg/*/init.sh`) and convert bare `echo`/`printf` to the appropriate `msg`, `log_info`, `log_warn`, or `log_error` calls. This gives consistent formatting, proper log capture, and better UX when debugging failed installs.

## Stream remote logs live

Remote execution pipes SSH output through `sed | tail | tee`, which buffers everything — logs appear only after the SSH session completes. During long installs (docker pulls, locale generation), the user sees `Setup of machines in progress...` with no feedback, and the log file on localhost is empty until the remote finishes.

**Proposed fix**: Write logs live on the remote host (e.g. `tee` to a remote log file inside the payload template) so they can be inspected during install with `ssh myhost tail -f /tmp/cloudify/logs/...`. Also surface the log path to the user in the "Setup of machines in progress..." message so they know where to look.

## Per-package remote env var declarations

### Problem

When `cloudify --on hermes install open-webui` runs, a fresh bash session starts on the remote host. It knows nothing about local env vars. The bridge is the payload template in `lib/remote.sh`, which uses `envsubst` with a hardcoded allow-list to substitute local values into the remote payload.

Currently, every env var that must reach the remote host requires **two manual edits** in `lib/remote.sh`:
1. Add `export MY_VAR='$MY_VAR'` to `cloudify_remote_payload_template()`
2. Add `$MY_VAR` to the `envsubst` allow-list string

If either is forgotten, the var arrives empty on the remote — no error, no warning, just silent default behavior.

This means the cloudify core (`lib/remote.sh`) must be modified every time a package needs a new env var remotely. The open-webui package (`WEBUI_ADMIN_EMAIL`, `WEBUI_ADMIN_PASSWORD`), rclone (`CLOUDIFY_RCLONE_REMOTE_*`), restic (`RESTIC_PASSWORD`), etc. — all required touching cloudify core. This does not scale.

### Design constraint

`envsubst` with an explicit allow-list is intentional and must stay. Without it, `envsubst` would expand *every* `$VAR` in the template — including ones like `$HOME`, `$(...)`, and backticks that must resolve on the remote side, not locally. The allow-list is the security boundary.

### Proposed fix: `.remote-vars` convention

Each package declares its own remote vars in a file inside its directory:

```
pkg/open-webui/.remote-vars
pkg/rclone/.remote-vars
pkg/hermes-openwebui/.remote-vars
```

Format: one var name per line, comments allowed:

```
# pkg/open-webui/.remote-vars
WEBUI_ADMIN_EMAIL
WEBUI_ADMIN_PASSWORD
```

`cloudify_remote_sync()` would then:
1. Resolve which packages are being installed (already known at dispatch time)
2. Scan each package directory for `.remote-vars`
3. Collect all var names into a single deduplicated list
4. Dynamically build the `export` lines and the `envsubst` allow-list

The core vars (`CLOUDIFY_REMOTE_USER`, `CLOUDIFY_REMOTE_PWD`, `DEBUG`, etc.) would stay hardcoded in the template — they're infrastructure, not package-specific.

**Benefits:**
- Packages are self-contained — add a `.remote-vars` file, no core changes needed
- No silent failures — if a var is declared but not set locally, we can warn
- The allow-list security boundary is preserved
- Package authors can work independently without touching cloudify core

## Streamline hermes package: own its gateway setup + verification

Currently `hermes` installs CLI + `hermes-gateway` daemon, but the API server
(port 8642, `/health`) is configured by `hermes-openwebui`. This splits
responsibility: `hermes` can't verify its own work, and `hermes-openwebui` does
setup that belongs to `hermes`.

**Proposed fix:** Move API server configuration into `hermes` recipe.
`hermes-openwebui` only wires the Open WebUI connection (OPENAI_API_BASE_URL,
OPENAI_API_KEY) — it doesn't touch hermes internals. Then `hermes` gets a
`pkg_verify` that checks `http://127.0.0.1:8642/health`.

## Docker compose `--detach` for open-webui systemd service

### Problem

The open-webui systemd service currently uses `docker compose up --force-recreate` (`Type=simple`). The `--force-recreate` flag tears down and rebuilds the container on every restart, even when `docker-compose.yml` hasn't changed. This is wasteful — it causes unnecessary downtime and pulls a fresh container on every `systemctl restart`.

The original problem was that `docker compose up` (without flags) doesn't recreate a running container when its config changes (new env vars, port bindings). The `--force-recreate` band-aid forces recreation always, but the real fix is to let Docker handle config change detection natively.

### Proposed fix

Switch to `docker compose up --detach` in the systemd unit. In detached mode, Docker natively detects when the compose file changed (env vars, ports, volumes) and recreates the container automatically. When nothing changed, it's a no-op.

The systemd unit would need `Type=forking` instead of `Type=simple`, since `--detach` causes the compose process to fork and exit while containers run in the background. This is a well-established pattern for Docker-based systemd services.

**Risks:** systemd must correctly track the forked child PID. If Docker's fork behavior changes, systemd might consider the service "started" prematurely. This is low risk given Docker compose's maturity.

**Alternative:** Keep `--force-recreate` with `Type=simple` — simpler, works today, minor cost on restart. Switch to `--detach` only if the restart cost becomes a real problem.

## Review abort-on-first-failure policy in `pkg_depends`

`pkg_depends` (lib/package-api.sh) continues through package failures — it collects failed package names in `failed_packages[]` and proceeds to the next package. This matches the error-aggregation design principle but means one broken package doesn't stop the rest of an install.

With verification now in the same loop, a failing `pkg_verify` appends to `failed_packages` and the loop continues to the next package. This is consistent but worth reviewing: for some workflows (tight dependency chains), aborting on first failure might give clearer feedback than collecting all failures.

**Proposed action:** Evaluate whether an `--abort-on-failure` flag (or a per-invocation policy) is warranted. Default stays continue-on-failure (current behavior) unless a clear need emerges.

## k3s multi-cluster provisioning

Spin up isolated k3s clusters on the incus private cloud via a few lines of
ivps + cloudify. Design and required ivps/cloudify deltas are in
`scratchpad/ivps-cloudify-evolutions-proposal.md`. The keystone is per-cluster
tailnet tags (`tag:k3s-<cluster>`) with a scoped ACL grant, since multi-node k3s
requires a node mesh (UDP 8472, TCP 10250/6443) that our default ACL does not
permit between containers.

MVP scope: 1 server + N agents, flannel VXLAN with MTU corrected to 1230 for
the VXLAN-inside-WireGuard overlay, three recipes (`k3s-server`, `k3s-agent`,
`k3s-cli`). No cloudify core change required for MVP - the existing
`pkgs/<pkg>.yaml` env-forwarding covers `K3S_TOKEN`/`K3S_URL`. ivps needs
`tag create/delete`, `launch --tag`, and launch-waits-for-SSH.

**Status: SHIPPED (2026-08-10).** Recipes merged to master and validated live 3×:
spike (2026-07-31), manual 7-step cluster + ntfy helm deploy, and the
deployments-driven run (token from the store). Tailnet ACL grants for the node
mesh (`tag:cluster-<name> → same, 6443,8472`) + operator reach (`tag:workstation`
must exist on a real device — see ivps HISTORY 2026-08-10).

## cloudify configure re-run validation (token rotation deferred)

Prove `cloudify configure` (run-phase only, no re-download) on a simple split
package first, not on k3s. Rationale: the chosen vehicle (k3s join-token
rotation) is structurally impossible on a running single-server cluster — k3s
encrypts its etcd bootstrap data with a key derived from the token, so
changing the token breaks decryption (fatal "encrypted with different token").
Known k3s limitation; rotation requires cluster re-bootstrap.

Validating the configure run-phase on a simpler package (e.g. a fixture pkg
with a mutable config value) exercises the same cloudify machinery without
the k3s constraint. Track separately:
- configure re-run on a simple split pkg: value change + service stays up.
- k3s join-token rotation: only if/when a re-bootstrap story is designed.

## k3s HA control plane (embedded etcd)

Follow-on to k3s multi-cluster provisioning. Promote a cluster from 1 server to
3 servers running embedded etcd (Raft quorum, odd node count only). Same
recipes; server-1 boots with `--cluster-init`, servers 2-3 join with
`--server https://k3s-<cluster>-1:6443 --token`. The flags
`--cluster-cidr`/`--service-cidr`/`--flannel-backend`/`--disable=...` must be
byte-identical across servers or the join fails.

Not a one-way door: a running single-server cluster converts to HA by
restarting the server with `--cluster-init` then joining more servers. So this
is additive over the MVP and does not constrain the MVP design.

## k3s with Tailscale CNI (drop VXLAN)

Endgame CNI for k3s over the tailnet. Replace flannel VXLAN with the Tailscale
Kubernetes operator's CNI so each pod gets a native tailscale 100.x IP. Removes
the VXLAN-over-WireGuard double encapsulation (and the 1230 MTU workaround
entirely), makes pods first-class tailnet citizens reachable directly from the
operator, and eliminates UDP 8472 from the node-mesh requirement.

Cost: an extra component (the operator) and every pod consuming a tailnet IP.
This is the "make it native" path, not day-1. The node mesh grant
(`tag:k3s-<cluster> -> tag:k3s-<cluster>:*`) is still required for the control
plane (6443/10250) even with the Tailscale CNI.

## Recipe fail-fast on mid-step errors

A recipe can exit 0 despite a failed middle step: recipes run in the
pkg_depends dep subshell where errexit is suspended, so a failing command
(unzip missing, install "cannot stat") doesn't stop execution — the last
line succeeds and cloudify reports SUCCESS (an exit-0 lie). Proven on
package-yazi (2026-08-10). Tracked: issue #14. Low-risk subset (explicit
`die` on critical steps) applied per-recipe as needed; systemic change
deferred pending an audit of recipes that deliberately tolerate failures.

## Idea 3: runbook generator (non-urgent)

The declarative extreme: a deployment declares roles + pkgs + exposure, and a
generator emits the cloudify-runbook steps (see URGENT runbooks b) from pkg
boundaries instead of hand-writing them. Enabled only when packages are
self-describing (declared vars with kinds, lifecycle legs) and deployment var
BINDINGS exist - e.g. guacamole `RDP_PASSWORD` = xfce `XFCE_USER_PASSWORD`,
or a role-derived address `guacamole.RDP_HOST := guest.tailnet_name`. Do not
build an inference engine now: keep runbook steps data-shaped so a generator
can be added later and validated by comparing generated vs hand-written
runbooks on the same application. Lifecycle: explore manually (agent runbook)
-> codify (cloudify runbook) -> generate (this idea).

## Per-target credentials (design question, 2026-09-07)

`~/.config/cloudify/credentials` is per OPERATOR machine and single-valued: one
remote SSH user/password and one local sudo password, used for every target.
Heterogeneous fleets (different admin credentials per host) are not expressible.
Decide later: host-scoped credentials (e.g. per-node in the ivps tree, or a host
section in the credentials file) vs relying on per-host SSH keys/MagicSSH.
No urgent driver.

## Secrets: resolver seam (design, 2026-09-07)

Goal: a vault-like backend later, without changing packages or the collector.
Seam, grounded in current code: one helper `_cloudify_resolve_var_value <name>
<raw>` inserted before the three value-entry exports - `_try_claim` (lib/remote.sh,
global + per-pkg machine files), `_try_claim_env` (caller env),
`_cloudify_deployment_read_vars` (lib/deployments.sh:178). Today identity.
A raw value matching `@<backend>:<locator>` resolves via
`_cloudify_secret_backend_<backend> <locator>`; anything else passes through.
Backends are plugins: `lib/secrets/*.sh` glob-sourced by `lib/secrets.sh`,
mirroring `lib/shadow.sh` -> `lib/shadows/*.sh`.
Scope: at rest only (config holds a reference); in transit the plaintext still
reaches the host via the payload, so single-quoting + debug masking stay
mandatory. Backend failure = die with a clear message, never forward empty.
Write path unchanged (`vars set --stdin` stores a literal or a reference).
