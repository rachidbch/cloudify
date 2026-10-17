# Cloudify Roadmap

## URGENT - clean the surface before anything else (2026-09-07 E2E traps)

Policy: compose-ability. Fix at the root (CRITICAL GATE where lib/router touches code), then revisit the deployment-runbook section below.

- [X] `vars` sits outside `deployment` and needs ambient `CLOUDIFY_DEPLOYMENT`. Fix: explicit flag `cloudify vars set|show|list|delete <key> [<value>] --deployment <id>` (omitted = ambient). Standardize on the existing flag idiom.
- [X] Forwarding truth (corrected 2026-09-07, from lib/remote.sh): only the ENV path is declaration-gated; file stores (global file, machine values, deployment) forward unconditionally. So an undeclared env var is silently inert, and it cannot be warned at set time (env is a shared user namespace; cloudify never sees undeclared names). Mitigation = the pkg-writing standard below (declaration kept in sync with the recipe).
- [X] Stale postgres volume breaks DB auth. Resolution (decided 2026-09-07): NO defensive guard. Uninstall leg owns teardown (`compose down -v` BEFORE removing the project dir); configure leg converges the DB credential via the postgres local socket; compose semantics replace bash wait loops. Requires the framework uninstall action + a guacamole 3-leg rewrite.
- [X] `verify` is a local subcommand plus a flag alias, so remote verify-only needs `--verify install` and the symmetric form fails with a misleading "no packages found" error. Resolution (decided): make `verify` a first-class action in both contexts (`cloudify --on <host> verify <pkg>`), keep `--verify install` as the alias (extends ADR-004), and fix the parser error when trailing words are not packages.
- [ ] Password handoff: xfce env-passed passwords are never printed; a glued deployment must carry them. Resolution (decided 2026-09-07): secrets are ordinary vars plus hygiene (`vars set --stdin`, masking, references in the state registry). The real gap is one value needing two names (xfce user password = guacamole RDP password). Now: documented convention (set both from one deployment value, as the E2E did); later: deployment var bindings (general derived-var feature, ROADMAP). ADR-017 covers standalone generate+print.
- [X] Human URLs use tailnet names (MagicDNS), never IPs; guacamole serves at root. Resolution (decided 2026-09-07): user-facing URLs and cross-host references use MagicDNS names; address-shaped values (the bind) are derived at run time from the host's own tailnet identity, never hardcoded; validate once that guacd resolves MagicDNS from inside the compose network; capture the rule in the cloudify skill.
- [X] Naming defaults: package defaults must be neutral or required; identity-specific values belong in config. Resolution (decided 2026-09-07): guacamole admin default `rbc` -> `guacadmin` (Guacamole's seeded name; no rename when unset). `gui`/`GUI` stay neutral. No skill item (common sense); the discovery fix is the reader command below.

### Vars CLI + declaration (decided 2026-09-07)

- [X] Vars CLI, flag-scoped, mutually exclusive: `cloudify vars show|set|unset|list <key> [<value>] [--global | --pkg <name> | --deployment <id>]`; no flag = ambient `CLOUDIFY_DEPLOYMENT`, error with hint if unset.
- [X] Repo declaration `pkg/<name>/.remote-vars` carries the pkg-writing standard; no drift-detection machinery, the cloudify skill carries the rule "edit recipe defaults and the repo declaration in sync".
- [X] Pkg-writing standard for vars (decided 2026-09-07): required `NAME`; defaulted `NAME=value` (declaration mirrors the recipe default; the recipe's `${NAME:-value}` stays runtime truth, so local and remote installs behave the same); optional `NAME=` (empty = absent, silent). Declaring a name is what makes the env path forward it.
- [X] Package lifecycle rule (extends ADR-008, decided 2026-09-07): install provisions (create-if-absent, never mutates existing config), configure configures (applies desired config, including convergence), uninstall tears down (down -v then remove the project dir). Needs a real `uninstall` action in the router (today a stub) + optional `uninstall.sh` per pkg with a defined default.
- [X] Compose-semantics-first (pkg-authoring docs, decided 2026-09-07): express service behavior with compose (`healthcheck`, `depends_on: condition: service_healthy`, `restart`, `env_file`, `docker compose up -d --wait`), never bash wait loops or hand-rolled checks. Guacamole's install/config/uninstall legs are the reference rewrite (also evaluate mounting the schema under `/docker-entrypoint-initdb.d` instead of docker cp + psql).
- [X] Reader command: `cloudify vars declared <pkg>` prints every consumed var with its kind, so the user sees the whole knob surface: `NAME` = required, `NAME=value` = defaulted (default shown), `NAME=` = optional (no default). Same three kinds as the pkg-writing standard; optionally append which source currently sets it (global/package/deployment/env).
- [X] Revive the state registry (unblocked since ivps node-as-dir landed): the registry is OBSERVATION, not a plan: per (deployment, target, package) status, timestamps, version, and a value snapshot (reference if the source was one, else raw; 600; never git), at `$(ivps node path <node>)/deployments/<id>/pkgs/<pkg>/config.yaml` (add `<instance>/` for an instance target). Replay is separate: playable runbook (plan) + values (deployment store + run snapshot) = `deployment run` (converge) / `deployment replay` (reproduce); it never enters the precedence ladder (`cloudify_vars_state_read` dropped). Targets are named slots bound at run time to `node` or `node:instance` (`--on X` / `X:` / `X:Y` / `:Y`; active = per-shell `CLOUDIFY_NODE`, else the ivps default; no localhost fallback). Supersedes ADR-011 pts 3/6/7 - amend when implementing.

### Vars internals + security (decided 2026-09-07)

- [X] Five-source naming refactor (URGENT): one read/write helper per source, one scheme - `cloudify_vars_{global,pkg,deployment,env}_read|write`, `cloudify_vars_state_read` (replay, read-only). The collector becomes a thin precedence walker over them, replacing `_try_claim`, `_try_claim_env`, `_cloudify_deployment_read_vars`.
- [ ] Optional post-MVP aware-consumer integration: compare controller-side and target-side resolution only if external environment injection proves insufficient.
  Secrets enter through the environment (ADR-037) supersedes the earlier planned Cloudify-owned vault lookup; see Optional secretspec-aware UX below.
- [X] Exposure inventory + rules: transit = SSH-encrypted; operator argv + config files hold plaintext in the operator-side model (host-side removes argv); host argv holds plaintext today -> harden by sending the payload via stdin, not argv; recipe state files 0600; cloudify's own config/state files hold references or hashes, never plaintext; software config files a recipe writes (compose .env) may hold secrets, 0600, unavoidable. Fundamental limit: the host must hold the plaintext; no vault removes that.
- [X] Cloudify skill: add a Security section (stars: payload via stdin not argv; references in cloudify state; masking PASSWORD/TOKEN/SECRET/KEY; 0600; no secrets in logs; the two vault models + the fundamental limit).

### Target config model (record; implement with the forwarding model above)

- [X] REPO: R1 recipe `${VAR:-default}` (weakest value layer); R2 `pkg/<name>/.remote-vars` = declaration, names only (contract, not a value).
- [X] MACHINE, applied in order, last wins: M1 `~/.config/cloudify/remote-vars.yaml` global default; M2 `~/.config/cloudify/pkgs/<pkg>.yaml` package values; M3 `~/.config/cloudify/deployments/<id>/` application values; M4 caller env (strongest).
### Runbooks (urgent; in order, after the trap cleanups)

- [X] a) Agent runbooks (docs, not code). Plain documents under a `runbooks/` tree in the cloudify repo, executed by an agent or human with ONLY ivps + cloudify commands. Tree = flavors: `runbooks/<app>/<flavor>.md`. Rules: no ad-hoc scripts; variable NAMES in steps, never values; addresses by MagicDNS name, never IP; explicit human-gate steps (render acceptance); explicit teardown steps. Validation = the amnesiac test: a fresh agent session given only the cloudify skill + the runbook path completes the deployment on disposable infra with no human hints; every stumble is a runbook defect. First candidate: rewrite plans/xfce-guacamole-e2e.md into runbooks/ under these rules.

- [X] b) Cloudify runbooks (`cloudify deployment run <id>`), after (a). Deployment declares targets + typed steps as data: launch, install, configure, verify, uninstall, human-gate. Addresses by name. Step outputs (e.g. the launched guest's tailnet name) live in the registry (deployment, target, package), never merged into intent config; later steps consume them live. Preflight validates required vars via `vars declared` before launching anything. Secrets referenced by name (five-source walker; optional vault on either end). Per-step security rules: payload via stdin, no secret in argv, masking. Build on the fixed surface only (trap cleanups first).

## Shared mutation permission and state distribution (2026-10-16)

- [ ] **What:** investigate NATS/JetStream or an equivalent shared service for permission to mutate deployments and for durable distribution of Cloudify events.
  These are separate jobs; publishing records after two competing changes does not prevent the changes.
- **Why:** controllers on different machines cannot coordinate through local file locks, and Git cannot decide which controller may change a deployment first.
  Git conflicts arrive after the machines may already disagree with their records.
- **First step:** one controller obtains exclusive permission for the whole deployment before mutation, refreshes the inventory, performs the work, publishes the resulting records, then releases permission.
  Define the authoritative inventory revision and what happens when publication fails before granting the next controller permission.
  Deployments sharing an installation must also share protection for that installation; different deployment names are not sufficient isolation.
- **Failure cases:** a controller losing contact with the shared service may still have work running on the target.
  Do not grant overlapping permission merely because a timer expired; prove the earlier work stopped or ensure the target rejects its further writes.
  Record crashes between host mutation and inventory publication as incomplete work to inspect, not completed work to overwrite.
- **End game:** start with whole-deployment protection, then test progressively smaller independent changes, such as different settings that do not restart or otherwise affect the same installation.
  Keep the coarse permission whenever independence has not been proved.
  Success means conflicting changes are prevented, with exceptional recovery reviewed by an agent and the human rather than routinely reconciled after Git conflicts.
- **Boundary:** a broker choice and its permission protocol need their own decision and failure tests.
  This entry does not authorize replacing Git, implementing a broker, or synchronizing secret values through it.

## IPv6 and the target `:` delimiter (non-urgent)

- [ ] The `node:instance` target syntax splits on the first colon, which collides with IPv6 literals (`fd42::1`) and `host:port` shaped values. `--on` is name-based today so it does not bite yet, but the delimiter must become unambiguous before targets accept addresses. Options: a distinct separator, bracket-wrapping IPv6 (`[fd42::1]`), or a `--node`/`--instance` flag pair instead of a delimiter.

## Target inventory adapter (non-urgent)

- [ ] Target resolution (is X a node? which node hosts instance X?) piggybacks on ivps inventory today. Put it behind a small adapter seam so cloudify can use ivps or another provisioning/inventory tool. Decide the adapter API (look up node/instance, list targets, provision).

## Inventory probe per runbook step (non-urgent)

**Problem:** every `cloudify` invocation re-probes the live inventory (`ivps list`, ~5s cap per node), and every runbook step is a fresh invocation - an N-step runbook costs N full probes, and one slow probe fails a step mid-run. Seen twice in one day: 2 of 5 two-host E2E runs died on a probe timeout.

- [ ] Share one probe across a run: cache the inventory on disk (state, 0600) with a short TTL, so a run's child processes reuse the parent's probe; TTL or `--refresh` invalidates; the resolver tests in `task gate` grow the cache cases. Cheap first move: probe only the node being resolved instead of the whole inventory.

**Constraint:** freshness stays a contract - the 2x2 timeout rule stays fail closed, the cache must never confirm an instance that moved, and ivps owns the data (cloudify caches only what ivps printed).

## Runbook teardown phase (non-urgent)

The runbook engine runs steps in document order with no phase concept, so a teardown section
placed after a `human-gate` is reachable by a plain `cloudify deployment run <id> --yes`: it
auto-confirms the gate and then immediately tears the deployment down. The only guard today is
operator discipline (`--from <id>`), which lives nowhere in the artifact.

- [ ] Fix: a `phase=install|reconfigure|verify|teardown` step attribute, defaulted from the step type, with `run` and `human-gate` steps declaring theirs. A bare run executes install then verify; teardown never runs as part of it. Decided in `REDESIGN.md` and ADR-022; implementation and recovery are tracked through `PLAN.md`. Runs the CRITICAL GATE. The teardown order itself is documented in `runbooks/README.md` ("Teardown contract").

## Remote bootstrap git pull vs task sync (non-urgent)

- [ ] The test container gets code from two writers into the same `/root/cloudify`: the bootstrap gist (`git pull` from GitHub) and `task sync` (rsync from the laptop). When a synced file is not yet in the container's checked-out commit, git sees it as untracked and refuses the pull ("untracked working tree files would be overwritten"), so the pull aborts and the clone stays stale; runs still use the synced tree. Reproduced 2026-09-10 on `cloudai:cloudify` with `lib/targets.sh`. Fix direction: bootstrap resets to the remote (`git fetch && git reset --hard`) or cleans untracked files before pulling; a remote-bootstrap change (brittle core), own gate.

## Pinned execution before safe historical teardown (state-model v2)

- [ ] Hosts pull the branch tip, so reconfigure or teardown cannot claim to execute the application commit recorded in state. Phase 7 of `PLAN.md` must pin remote execution and fail on commit drift before historical teardown is enabled. Automatic rebuild and command replay are deferred by ADR-022.

## Dispatch context as a JSON contract (state-model v2, proposal)

Status: a proposal for discussion. Not scheduled, not accepted, and nothing depends on it.

### What

Convert the private dispatch context from its flat `key: value` format to JSON, give it a
`schema_version: 1`, validate it against `schemas/v1/dispatch-context.schema.json` through
`schemas/v1/validate.sh`, and make local `jq` the one parent-side JSON encoder and validator.
The context is ephemeral and nothing persisted reads it, so there is no migration.

### The open design question (settle this before any code)

The context is, in production, a **resolution record**. The payload's allow-list, the registry
record, the run snapshot and the DEBUG rendering read only `value.<NAME>.*`; no production
consumer reads the identity fields. `ADR-024` settled the value scope (one namespace per
dispatch; the named package wins) and left those identity fields unused.

So this proposal has two shapes. The choice is the first thing to settle:

1. **Resolution record.** The context carries the resolved values and their provenance, plus
the identity fields that already exist: `action`, `deployment`, `phase`, `target`. JSON adds
the full per-name field set, machine checking and native multi-line values.
2. **Dispatch descriptor.** The context also describes the dispatch: application commit, run
and step IDs, package identity and package instance, each typed nullable while it has no
producer. The original design's field list implies this shape, and it would let every writer
read one file. Cost: the context grows a field whenever a writer needs one, and the parent
already holds every one of those facts.

### Why

Three gains, under either shape. The contract becomes machine-checked instead of checked by hand, so a malformed
context fails loudly rather than silently emptying the payload's name allow-list. Multi-line
values become native, so the `@base64:` convention is no longer needed inside the context
(it stays in the registry record and the run snapshot, which are user-visible). And one
encoder replaces the hand-rolled writer and its hand-rolled reader.

### Why it was deferred

The conversion itself is what turns four existing readers into silent failures. Today they
parse flat lines, and every one of them returns nothing rather than erroring once the file is
JSON:

- the allow-list name extraction in `lib/remote.sh`, which decides which names are substituted
- `cloudify_context_read` in `lib/context.sh`
- the DEBUG rendering loop in `lib/remote.sh`, through that reader
- the snapshot's value lookup in `lib/runbooks.sh`

Missing the first one stops payload forwarding from exporting package values **with no error
message**. The Phase 2 repair does not need the format change: it needs one added field, the
raw source form, which the flat format carries equally well. So the format change was split
out rather than ridden along with a repair to the most breakage-prone code in the repository.

### Proposed steps

One slice, its own consent and its own review. It is deliberately unscheduled: nothing depends on it, because the state and event writers take identity from the parent (`ADR-024`) and read only the context's values, which the flat format already carries. It is a quality improvement waiting for a slot, not a prerequisite of any phase.

1. Fix the field set and write `schemas/v1/dispatch-context.schema.json`: for each declared value, its declaration kind, source label, source form, raw source form, resolved runtime form and secret classification origin, plus the dispatch fields of the chosen shape, with every field that has no producer yet typed nullable. Add valid and invalid fixtures.
2. Add `dispatch-context` to the artifact list in `schemas/v1/validate.sh` and update
   `schemas/v1/README.md`: file list, field lists, validator description, and the
   `schema_version` rule that currently covers four schemas.
3. Confirm `jq` is present on the operator machine before any state work, fail with an
   install hint if it is not, and change nothing about the remote bootstrap.
4. Convert the four readers in one commit, each with a test that fails if it returns nothing
   for a valid context. This is the step that carries the risk; do not split it.
5. **Preserve the payload bytes.** The context's entries are written in the ledger's `sort -u`
   order today, that order becomes the allow-list order, and that becomes the payload's export
   order, pinned byte-for-byte by the eight `tests/fixtures/golden/payload/*` cases. A JSON
   writer that emits keys in hash order changes the payload. Emit sorted, and prove it by
   keeping those eight cases byte-identical with `cmp`.
6. Replace `context_version: 1` with `schema_version: 1`, and drop the `@base64:` convention
   inside the context once the value can carry a newline natively.
7. Validate the context before payload construction and before any mutation, and reject a context with a missing expected field or an unexpected field.

Acceptance: the eight payload golden cases and the nine registry record golden cases stay
byte-identical; each converted reader has a test that fails when it returns nothing; the
context schema and its fixtures pass `bash schemas/v1/validate.sh`.

## Mixed local/remote host list dispatch (non-urgent)

- [ ] `_cloudify_dispatch` picks local vs remote once for the whole run (only when the host list is exactly `localhost`). A list containing `localhost` plus a remote host (`--on localhost cloudai ...`, or a tag expanding to both) sends the whole run down the remote path; the `localhost` leg then receives the package text as one already-joined argument (`cloudify "verify bats-test"`) and dies `Unknown argument`. Reproduced 2026-09-10 with a read-only `verify`. Fix: decide per host, and carry packages as a list, not a string.

## apt dpkg lock race (non-urgent)

**What happened:** `cloudify uninstall xfce` failed with `E: Could not get lock /var/lib/dpkg/lock-frontend ... held by process (unattended-upgr)`; the recipe's `apt-get purge || die` turned a transient lock into a hard failure. The xfce uninstall leg now passes `-o DPkg::Lock::Timeout=300`, but the shadow `apt-get install`/`update` paths do not, so any install can hit the same race.

**Why:** Ubuntu runs `unattended-upgrades` on a timer and it holds the dpkg lock. The shadow apt-get runs `sudo apt-get -qq install`/`update` with no lock wait.

- [ ] **Plausible fixes to study:** add `-o DPkg::Lock::Timeout=<n>` to the shadow's install/update calls (framework-wide, CRITICAL GATE); or a preflight that waits for the lock before any package action; or a package-api helper recipes must call. Trade-off: an unbounded wait can hide a genuinely stuck apt; prefer a bounded wait with a clear message.

## shadow sudo requires a password even as root (non-urgent)

**What happened:** `cloudify --on localhost uninstall xfce` from a shell without `CLOUDIFY_LOCAL_PWD` died silently; the shadow `sudo` calls `die "Password not set for user ... on host ..."`, and the message was lost in the remote tee, so the failure looked like a mid-recipe abort and cost diagnosis time.

**Why:** the shadow always injects a password via a herestring; it never tries `sudo -n` first. Running as root (or with a valid sudo timestamp) needs no password, so the requirement is artificial in that case. The failure is also silent.

- [ ] **Plausible fixes to study:** try `command sudo -n "$@"` first and fall back to the password path; ensure the shadow's `die` message always reaches the log (flush/log before exit); otherwise document that `--on localhost` needs `CLOUDIFY_LOCAL_PWD`.

## bash usage spam during installs (non-urgent)

**What happened:** xfce/guacamole installs emit repeated `bash: - : invalid option` lines plus a full bash usage block, and `comm: file 2 is not in sorted order`; a fresh reader reads them as failures.

**Why:** some command invokes `bash -` (or with a bad flag), and a `comm` runs on unsorted input.

- [ ] **Plausible fixes to study:** find the caller (likely a shadow or the verify hook) and fix the invocation; sort before `comm`.

## Node MagicDNS name command gap (non-urgent)

**What happened:** the amnesiac runbook needs the guest's full MagicDNS name (`<node>.<tailnet-domain>`) for cross-host references. `ivps status <remote:name>` prints the Tailscale IP only, `cloudify info` prints the LAN IP, and `cloudify exec <host> 'tailscale ip -4'` output carries the `host: ` prefix. The bare container name resolves to an Incus-internal address on the same node.

**Why:** no command returns a node's MagicDNS FQDN cleanly, so runbooks cannot derive it as the rules require (MagicDNS names, never IPs).

- [ ] **Plausible fixes to study:** `ivps status`/`ivps info` gains a MagicDNS field (or `--json`); or `cloudify info <host> magicdns`.

## cloudify host/info subcommand gaps (non-urgent)

**What happened:** the cloudify skill documents `cloudify host <host>` and `cloudify info <host> [ipv4|ipv6]`. `cloudify host cloudify` fails with `Error: Unknown argument 'host'`; `cloudify info cloudify` (non-inventory host) fails with `lib/hosts.sh: line 97: $1: unbound variable`.

**Why:** the router has no `host` subcommand, and `cloudify_info` reads `$1` without a guard.

- [X] **Plausible fixes to study:** add the `host` subcommand or remove it from the skill; guard `cloudify_info` for a missing/unknown host with a clear error.

## Tag-to-tag tailnet reachability (non-urgent)

**What happened:** the runbook's guacamole host and guest are both `tag:incus`; Tailscale denies tag-to-tag by default, so the guest was unreachable until an explicit grant. The correct form is `ivps acl grant <guest> --src tag:incus --port 3389` (dst positional, `--src` required).

**Why:** the default ACL covers `autogroup:member` and `tag:node`, not `tag:incus` to `tag:incus`.

- [X] **Plausible fixes to study:** document the pattern in the ivps/runbook docs; or a runbook helper that derives and grants the required reachability.

## guacd MagicDNS resolution check (non-urgent)

**What happened:** the runbook sends the guest's MagicDNS name as the Guacamole RDP host, but nothing proves guacd resolves MagicDNS from inside its compose network except the human render gate.

- [X] **Plausible fixes to study:** a check (a compose healthcheck or a `verify.sh` step) that resolves the name from inside the guacd container.

## Resolution precedes every phase (non-urgent)

- [ ] Today install/configure/uninstall resolve vars through the walker, and verify fills unset names from the package yaml (verify-only has no walker). Cleaner: make resolution a step that always precedes a phase, verify-only included, then remove the source read from verify. Effect: verify never re-reads a source, so there is no precedence question inside verify. Cost: verify-only would apply the full five-source ladder instead of the package yaml alone, and remote verify-only forwarding would need a decision. Not needed for the parent-override fix already shipped.

## Dependency garbage collection (non-urgent)

- [ ] Uninstall removes only the named package; dependencies are never auto-removed (they may be shared). Future: scan the inventory and uninstall packages and dependencies no longer needed by anything. Inputs: the per-node state registry (what landed, keyed by deployment, instance, package) plus each recipe's `pkg_depends` graph. Output: a candidate list for explicit user consent, never an automatic purge. Depends on the state registry.

## Package discovery: one-liner descriptions in `cloudify packages`

`cloudify packages` lists package names only — no descriptions. To discover what a package does, users must read `pkg/<name>/init.sh` individually. Each init.sh already has a header comment (e.g. `# bat is better cat`).

- [ ] **Proposed:** `cloudify packages` reads each init.sh header comment and displays a one-liner description column. Format options:
- `cloudify packages` — name + description (compact table)
- `cloudify packages show <pkg>` — full recipe (already exists)

Implementation: extract lines 2–3 from each init.sh (the `# description` pattern), strip `#` prefix. Non-invasive — no new files or convention changes needed.

## Error aggregation in `cloudify_install_package`

`cloudify_install_package()` in `lib/packages.sh` calls `pkg_depends "$pkg"` in a loop, one package at a time. With `set -e` active, the first failure aborts the entire function — remaining packages are never attempted, and no error report is printed.

This is inconsistent with the design principle that **error aggregation belongs at the orchestration level**. `pkg_depends` already collects errors within a single call, but `cloudify_install_package` doesn't benefit from it when installing multiple packages (e.g. `cloudify install foo bar baz`).

- [ ] **Proposed fix**: Apply the same error-collection pattern — continue through failures, collect failed package names, report comprehensive list at end.

## Parity between local and remote logging

Remote execution (`cloudify install foo --on myhost`) captures all stdout/stderr in `$CLOUDIFY_LOG_FILE` via `tee -a`. Local execution (`cloudify install foo`) only logs `msg`/`log_*` calls — bare `echo`, command output, and subcommand errors from package recipes are lost.

- [ ] **Proposed fix**: Tee local package execution to the log file the same way `cloudify_remote_sync` does for localhost (remote.sh:74). This ensures local installs produce the same complete log as remote ones.

## Audit package recipes for proper logging

Many packages use bare `echo` instead of `msg`/`log_*` functions, so their output is not captured in `$CLOUDIFY_LOG_FILE` and has inconsistent formatting. Example: `pkg/hermes/init.sh` uses no `msg` or `log_*` calls at all.

- [ ] **Proposed fix**: Review all package recipes (`pkg/*/init.sh`) and convert bare `echo`/`printf` to the appropriate `msg`, `log_info`, `log_warn`, or `log_error` calls. This gives consistent formatting, proper log capture, and better UX when debugging failed installs.

## Stream remote logs live

Remote execution pipes SSH output through `sed | tail | tee`, which buffers everything — logs appear only after the SSH session completes. During long installs (docker pulls, locale generation), the user sees `Setup of machines in progress...` with no feedback, and the log file on localhost is empty until the remote finishes.

- [X] **Proposed fix**: Write logs live on the remote host (e.g. `tee` to a remote log file inside the payload template) so they can be inspected during install with `ssh myhost tail -f /tmp/cloudify/logs/...`. Also surface the log path to the user in the "Setup of machines in progress..." message so they know where to look.

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
- [X] Resolve which packages are being installed (already known at dispatch time)
- [X] Scan each package directory for `.remote-vars`
- [X] Collect all var names into a single deduplicated list
- [X] Dynamically build the `export` lines and the `envsubst` allow-list

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

- [ ] **Proposed fix:** Move API server configuration into `hermes` recipe.
`hermes-openwebui` only wires the Open WebUI connection (OPENAI_API_BASE_URL,
OPENAI_API_KEY) — it doesn't touch hermes internals. Then `hermes` gets a
`pkg_verify` that checks `http://127.0.0.1:8642/health`.

## Docker compose `--detach` for open-webui systemd service

### Problem

The open-webui systemd service currently uses `docker compose up --force-recreate` (`Type=simple`). The `--force-recreate` flag tears down and rebuilds the container on every restart, even when `docker-compose.yml` hasn't changed. This is wasteful — it causes unnecessary downtime and pulls a fresh container on every `systemctl restart`.

The original problem was that `docker compose up` (without flags) doesn't recreate a running container when its config changes (new env vars, port bindings). The `--force-recreate` band-aid forces recreation always, but the real fix is to let Docker handle config change detection natively.

### Proposed fix

- [ ] Switch to `docker compose up --detach` in the systemd unit. In detached mode, Docker natively detects when the compose file changed (env vars, ports, volumes) and recreates the container automatically. When nothing changed, it's a no-op.

The systemd unit would need `Type=forking` instead of `Type=simple`, since `--detach` causes the compose process to fork and exit while containers run in the background. This is a well-established pattern for Docker-based systemd services.

**Risks:** systemd must correctly track the forked child PID. If Docker's fork behavior changes, systemd might consider the service "started" prematurely. This is low risk given Docker compose's maturity.

**Alternative:** Keep `--force-recreate` with `Type=simple` — simpler, works today, minor cost on restart. Switch to `--detach` only if the restart cost becomes a real problem.

## Review abort-on-first-failure policy in `pkg_depends`

`pkg_depends` (lib/package-api.sh) continues through package failures — it collects failed package names in `failed_packages[]` and proceeds to the next package. This matches the error-aggregation design principle but means one broken package doesn't stop the rest of an install.

With verification now in the same loop, a failing `pkg_verify` appends to `failed_packages` and the loop continues to the next package. This is consistent but worth reviewing: for some workflows (tight dependency chains), aborting on first failure might give clearer feedback than collecting all failures.

- [ ] **Proposed action:** Evaluate whether an `--abort-on-failure` flag (or a per-invocation policy) is warranted. Default stays continue-on-failure (current behavior) unless a clear need emerges.

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

- [X] **Status: SHIPPED (2026-08-10).** Recipes merged to master and validated live 3×:
spike (2026-07-31), manual 7-step cluster + ntfy helm deploy, and the
deployments-driven run (token from the store). Tailnet ACL grants for the node
mesh (`tag:cluster-<name> → same, 6443,8472`) + operator reach (`tag:workstation`
must exist on a real device — see ivps HISTORY 2026-08-10).

## cloudify configure re-run validation (token rotation deferred)

- [ ] Prove `cloudify configure` (run-phase only, no re-download) on a simple split
package first, not on k3s. Rationale: the chosen vehicle (k3s join-token
rotation) is structurally impossible on a running single-server cluster — k3s
encrypts its etcd bootstrap data with a key derived from the token, so
changing the token breaks decryption (fatal "encrypted with different token").
Known k3s limitation; rotation requires cluster re-bootstrap.

Validating the configure run-phase on a simpler package (e.g. a fixture pkg
with a mutable config value) exercises the same cloudify machinery without
the k3s constraint. Track separately:
- [ ] configure re-run on a simple split pkg: value change + service stays up.
- [ ] k3s join-token rotation: only if/when a re-bootstrap story is designed.

## k3s HA control plane (embedded etcd)

- [ ] Follow-on to k3s multi-cluster provisioning. Promote a cluster from 1 server to
3 servers running embedded etcd (Raft quorum, odd node count only). Same
recipes; server-1 boots with `--cluster-init`, servers 2-3 join with
`--server https://k3s-<cluster>-1:6443 --token`. The flags
`--cluster-cidr`/`--service-cidr`/`--flannel-backend`/`--disable=...` must be
byte-identical across servers or the join fails.

Not a one-way door: a running single-server cluster converts to HA by
restarting the server with `--cluster-init` then joining more servers. So this
is additive over the MVP and does not constrain the MVP design.

## k3s with Tailscale CNI (drop VXLAN)

- [ ] Endgame CNI for k3s over the tailnet. Replace flannel VXLAN with the Tailscale
Kubernetes operator's CNI so each pod gets a native tailscale 100.x IP. Removes
the VXLAN-over-WireGuard double encapsulation (and the 1230 MTU workaround
entirely), makes pods first-class tailnet citizens reachable directly from the
operator, and eliminates UDP 8472 from the node-mesh requirement.

Cost: an extra component (the operator) and every pod consuming a tailnet IP.
This is the "make it native" path, not day-1. The node mesh grant
(`tag:k3s-<cluster> -> tag:k3s-<cluster>:*`) is still required for the control
plane (6443/10250) even with the Tailscale CNI.

## Recipe fail-fast on mid-step errors

- [ ] A recipe can exit 0 despite a failed middle step: recipes run in the
pkg_depends dep subshell where errexit is suspended, so a failing command
(unzip missing, install "cannot stat") doesn't stop execution — the last
line succeeds and cloudify reports SUCCESS (an exit-0 lie). Proven on
package-yazi (2026-08-10). Tracked: issue #14. Low-risk subset (explicit
`die` on critical steps) applied per-recipe as needed; systemic change
deferred pending an audit of recipes that deliberately tolerate failures.

## Idea 3: runbook generator (non-urgent)

- [ ] The declarative extreme: a deployment declares roles + pkgs + exposure, and a
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

- [ ] `~/.config/cloudify/credentials` is per OPERATOR machine and single-valued: one
remote SSH user/password and one local sudo password, used for every target.
Heterogeneous host sets (different admin credentials per host) are not expressible.
Decide later: host-scoped credentials (e.g. per-node in the ivps tree, or a host
section in the credentials file) vs relying on per-host SSH keys/MagicSSH.
No urgent driver.

## Secrets: resolver seam (historical implementation, 2026-09-07)

The entry below describes existing reference-resolver code, not the revised MVP boundary.
Secrets enter through the environment (ADR-037) supersedes Cloudify-owned secret resolution for the new design; optional awareness is post-MVP.

- [X] Goal: a vault-like backend later, without changing packages or the collector.
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

## Open decisions (state-model v2, pending Rachid)

Concluded decisions live in ADR.md and the design docs; this section tracks only the open ones.

- [X] **Host origin and continuity (ADR-028, decided 2026-09-18)**: baseline = machine origin identity (base image fingerprint, created-at; `discovered|asserted|unknown`) bound to a continuity anchor (ivps host id + last-seen boot id); every dispatch compares before mutation; replaced or rewound machines fail before mutation until verify or re-adoption.
- [ ] **ivps instance records** (shape approved 2026-09-18, implementation pending in the ivps repo): `nodes/<node-id>/instances/<instance-id>/instance.json` (immutable id, name, engine, base image fingerprint, created-at, engine uuid; human scanability first), written by `ivps launch`/`node adopt`, backfilled lazily; `ivps node path <node>:<instance>` returns the id-keyed dir. Unlocks cloudify `ivps:<node-id>:<instance-id>` keys, instance inventory roots, and the ADR-028 origin fingerprint. Blocks cloudify 4.2 (the two-host E2E hosts are `ivps launch`ed instances).

## Controller state durability (2026-09-23, surfaced by the affine adoption backup contract)

- [ ] The controller's own state is irreplaceable with no cure today: `~/.config/cloudify/` (credentials + every stored value incl. secrets in plaintext behind 0600), `~/.local/state/cloudify/` (manifests + the event audit log), `~/.config/ivps/` (the inventory tree, now also holding the per-host package records). A controller loss orphans every deployment: machines keep running, cloudify forgets identities, audit, values, inventories. Cure TBD: a backup/export path (must encrypt the secret-bearing parts - the bucket is never a second live copy of a credential), or a documented external-backup scope. Interim: PKG-ADOPTIONS backup contracts name it in the external agent's scope.

## Human-readable ivps inventory and rename safety (reopened 2026-10-16)

- [ ] **What:** revisit name-keyed directories while keeping immutable ids in records.
  Current instance record: `/home/rbc/.config/ivps/nodes/d12a512b2b0ebc14/instances/311bbdd276b8bc91/instance.json`.
  Rachid's proposed shape: `/home/rbc/.config/ivps/nodes/cloudstation/instances/guac-gui/id.json`, with the node identity also in `id.json`.
- **Why:** readable names make the inventory easier for humans and agents to navigate without a lookup command for every directory.
  The earlier candidate was name symlinks over id directories; compare that with moving name-keyed directories during rename rather than assuming either wins.
- **How:** keep immutable ids as identity, resolve current paths through ivps, and move the complete node or instance directory on rename, including Cloudify-owned contents.
  Cover interrupted renames, concurrent readers, name collisions, Git changes, node deletion, and instance discovery under a changed name.
  Cloudify currently derives durable host ids from directory names; change that assumption to read the identity record before changing directory layout.
  Test that a rename preserves deployment identity, applied settings, target bindings, and shared-installation protection.
- **Decision boundary:** this is ivps-owned work and a proposed revisit of ivps's immutable-directory decisions, not permission to change them.
  Surface the departure from Immutable node identity (ivps ADR-009), Instance inventory records (ivps ADR-010), and Deployment-first inventory (Cloudify ADR-026) before implementation.

## XDG homes for ivps configuration and inventory (2026-10-16)

- [ ] **What:** separate operator configuration and credentials from machine-owned inventory rather than keeping both under `/home/rbc/.config/ivps/`.
- **Why:** the current directory mixes settings with observed cloud records, complicating permissions, backup, Git allowlists, and reasoning about which files are portable state.
  Cloudify already separates configuration from local state, although its host-bound records inherit ivps's current location.
- **How:** classify ivps files as configuration, persistent data, state, or cache against the XDG specification, then decide the inventory's home.
  Coordinate with ivps's existing fleet-state/Git plan rather than introducing a second relocation mechanism.
  Specify an explicit migration and rollback; keep credentials out of tracked inventory.
  Test `ivps node path`, Cloudify record discovery, rename, sweep, adoption, and inventory-only recovery after relocation.
- **Boundary:** do not move files or replace directories with symlinks in this discussion.
  The final XDG home and the name-keyed layout are separate decisions.

## Hermes pair out of test scope (2026-09-28, Rachid's ruling; history: 2026-08-10)

`package-hermes-dashboard` and `package-hermes-openwebui` are excluded from the
default integration run (`tests/run-integration.sh` OUT_OF_SCOPE list). They
were the two failures of the 2026-08-10 battery (ruled out of scope that day)
and failed identically in the 2026-09-28 full run. Root causes, proven live on
the test container:

- Vendor layout drift: the Nous installer now installs user-local
  (`~/.local/bin/hermes`, uv-managed) and no longer writes
  `/usr/local/bin/hermes` or `/usr/local/lib/hermes-agent`; the dashboard
  systemd unit's `ExecStart=/usr/local/bin/hermes ...` died `203/EXEC`.
  Partially fixed 2026-09-28: `pkg/hermes` now guarantees the system entrypoint
  (symlink + postcondition, v1.1.0).
- Vendor auth gate: the dashboard refuses non-loopback binds without an auth
  provider ("Refusing to bind dashboard to 0.0.0.0"), killing the long-standing
  `HERMES_DASHBOARD_PUBLIC=true` public mode. The value reaches test dispatches
  from the operator's production `pkgs/hermes-dashboard.yaml` via the recipe
  name-mention claim path (no `.remote-vars` exists anywhere; no caller env,
  no global declaration - the mechanism itself deserves a pinning test when
  this is revisited).
- hermes-openwebui test 5 (open-webui health after wiring): wiring values land
  (MagicDNS URL, API key, RAG engine greps pass); the service was healthy at
  install-verify time and dead at probe time; presumed the same vendor-era
  drift family (dashboard/API container interplay), unclassified - classified
  when the pair re-enters scope.

Re-entry conditions (the hermes adoption round, PKG-ADOPTIONS round two):
- `pkg/hermes-dashboard` public mode redesigned for the vendor gate: basic
  auth (username + password hash in `~/.hermes/config.yaml`, hashed via the
  venv python) or a documented loopback+reverse-proxy-only contract; a new
  var (e.g. `HERMES_DASHBOARD_PASSWORD`), declared in `.remote-vars`, docs.
- The claim path that forwards the yaml value without a declaration gets a
  pinning test or an explicit declaration, whichever the adoption round
  decides.
- hermes-openwebui test 5 root-caused (docker logs at failure time).
- Both removed from OUT_OF_SCOPE, full suite green.

## State-tree hygiene (2026-09-29, surfaced by the affine gap investigation)

Cleanup-session scope (plans/runbook-run-store-cleanup.md):
- `_direct` manifest accumulation: every bare dispatch leaves
  `~/.local/state/cloudify/deployments/_direct/direct/<pkg>-<ts>/` forever.
- Deleted-instance residue: package records survive under instance dirs of
  instances that no longer exist (the torn-down twin still holds records).
- `deployment delete` does not exist; teardown sweeps only what it knows.
- Manifest honesty per the 2026-09-29 rulings: rebuildable cache outside the
  projection path, declared vs derived fields, adoption pins no commit,
  status vocabulary adopted/installed/reconfigured/verified/degraded.

## Dispatch payload branch skew (found 2026-09-29, affine close-out; repo side landed 2026-09-30)

The bootstrap block pulls the remote's CURRENT branch (usually master). A controller running a feature branch dispatches payloads that execute master's code - the result-line contract (lib/results.sh) does not exist on master, so any dispatch reconciliation fails (`cause: reconcile`). The two-host e2e never sees this (it rsyncs the tree).

Landed 2026-09-30: the payload carries `CLOUDIFY_GIT_REF` - the controller's own branch by default (detached: its commit; no git: empty), an explicit env override, set-empty to disable. Reserved against file stores (lib/vars.sh). Goldens regenerated (one export line per payload) under the gate. Tests pick how a target gets code via `CLOUDIFY_TEST_CODE_MODE` (push | github | branch:<name>, push default) - tests/helpers/code-mode.bash.

REMAINING (Rachid, one paste): the bootstrap gist must honor the ref - the ready-to-paste version is `~/tmp/gist-with-git-ref.sh` (only the update block changes; the symlink logic is byte-identical). Until the gist is updated, remote checkouts keep their current-branch pull behavior and the mandate is inert.

## Bare multi-host invocation synthesis (ADR-032, ruled 2026-09-30 - LANDED same day)

Implemented: the router mints the invocation's one _direct name at dispatch entry (mutating actions only - a bare verify stays an ad-hoc observation: no records to seed against and it records nothing by the standing decision), carries it as the active deployment tuple for every dispatch of the invocation, and decorates each target triple with its binding slot (`direct` for a single host, the host's identity word when several). The workers merge their binding add-if-absent under the manifest lock (cloudify_state_binding_add) instead of each synthesizing a per-host deployment.

`cloudify --on h1 --on h2 install a b c` must leave ONE `_direct` deployment spanning both hosts (one manifest, one binding per host), not one bucket per host. The synthesis moves to invocation level in the router; manifest binding writes gain add-if-absent merge; `deployment delete` already sweeps every host tree (verified). Tests: two-host bare invocation unit + e2e pin.

## sudo shadow flattens argv into one bash -c string (found 2026-10-08, t3code close-out)

`lib/shadows/sudo.sh` wraps the `sudo` command inside recipes to inject the
host password. Its generic branch (`lineargs="${*}"`) joins EVERY argument -
including sudo's own flags - into ONE string and executes it as
`command sudo -kS -p "" bash -c "$lineargs" <<<"$password"`. Any invocation
whose first argument is a sudo flag therefore breaks: the flags become the
bash SCRIPT text, not sudo's argv. Proven live (t3code 1.0.0): the recipe's
user switching `sudo -u t3 env HOME=/home/t3 ... t3 --version` executed
`bash -c "-u t3 env HOME=..."` and bash died parsing `-u` as its own option
(`bash: - : invalid option`); the dispatch failed with a bash usage dump as
the only symptom. Worked around in the recipe (1.0.1: `runuser -u t3 -- env
...`, no shadow on runuser) - the workaround is load-bearing until this is
fixed; any recipe that must run a command as another user is stuck choosing
between runuser (fine as root dispatch) or this bug.

Secondary sharp edges in the same wrapper, fix in the same pass: it cats
stdin whenever present (`pipeargs="$(cat -)"`) to forward pipes, so a sudo
call at the top of a pipeline hangs or swallows the stream if stdin is a
slow producer; and the >10000-char branch re-executes `"$lineargs" "$tfile"`
which is only correct for file-taking commands.

Fix direction: split sudo's own flags (`-u`, `-g`, `-E`, `-p`, `--`) from the
command words; rebuild as `command sudo -kS -p "" <flags> <cmd words...>
<<<"$password"` - the bash -c wrapping exists ONLY to re-create piped stdin,
so argv-split execution is correct for the no-pipe case and the pipe case
keeps `bash -c` but with the command words quoted individually, never
pre-joined. Pin with unit tests: `sudo -u user env A=B cmd --flag` (flags
survive), leading-flag invocations, piped-stdin case, >10k case.

Constraint: `lib/shadows/*` is fragile surface (project AGENTS.md CRITICAL
GATE) - byte-exact goldens cover the shadow contracts. This entry is the
written proposal; implementation waits on Rachid's go + gate run.

## GUI keyboard capture: evasive tests on a disposable container (Rachid, 2026-10-12)

The GUI oracle (`cloudstation:guac-gui`, XFCE + xrdp + Guacamole in browser)
loses Super/Alt/Ctrl combos to the Windows host before the browser sees them.
Consequence chain: i3 (keyboard-driven tiling) is blocked in the browser leg,
Cortile (auto-tiling, keyless) was chosen instead (2026-08-31). Guacamole
stays the default web gateway - Rachid evaluated the alternatives before
adopting it and non-paying options were worse; "connect with mstsc instead"
is not the default path (also: Windows is de-emphasizing its RDP client -
countless disgruntled-user reports). On-screen keyboards are rescue tools,
never the workhorse.

What the field does (Apache lists/Jira, 2023-2026): (a) accept it - Apache's
own stance is that a clientless web app cannot fully capture system shortcuts
(GUACAMOLE-2016); 1.6.0's fullscreen+keyboard-lock cannot override host OS
window management (Alt+Tab, Win stay host-side); (b) thick-client wrappers -
e.g. jochenwezel/GuacamoleClient: a WebView2 shell around the SAME Guacamole
web UI that intercepts keys a browser reserves (Alt+Tab works); (c) in-product
mitigations (on-screen keyboard GUACAMOLE-2277, meta-to-ctrl GUACAMOLE-2229,
Ctrl+Alt+End intercepts) - rescue-grade.

TEST PLAN (disposable container only - never on guac-gui; fresh ivps guest
with pkg/xfce + pkg/guacamole, the never-run clean rebuild doubles as the
vehicle):
1. Baseline matrix on current 1.6.0: fullscreen, keyboard-lock, which
   combos actually pass from a Windows host (record, don't assume).
2. Thick-client wrapper (GuacamoleClient/WebView2 or equivalent) against the
   same gateway: Alt+Tab, Win, Super-drives-i3 test - if i3 becomes usable
   through it, the 2026-08-31 i3 rejection is void.
3. Guacamole stack bump (1.6.0 -> current): meta-to-ctrl, on-screen keyboard,
   Meta/Super keysym fix (GUACAMOLE-1386) - measure what actually changes.
Success = a documented path where a keyboard-driven WM (i3 first candidate)
is fully usable; the winner lands as a pkg/runbook change, the oracle
migrates only after Rachid's go.

## secretspec generate=true: first-boot secrets minted into the store, not transcribed (Rachid, 2026-10-13)

Environment-only secrets (ADR-037) leaves generation to the external wrapper for the MVP; the end-user workflow and guest-generated secret handling remain deferred.
Some packages mint first-boot secrets on the guest: k3s can generate a join token, octop writes a one-time wizard password, and affine prints a master token.
Cloudify-owned secret capture is superseded by Secrets enter through the environment (ADR-037); current snapshots do not provide a general protected channel for returning guest-generated secrets to a provider.
Distinguish capturing a supplied value from retrieving a value created on the guest.

secretspec's per-secret `generate = true` + `type` (password, hex, uuid) can invert the flow: create a missing value in the provider before supplying it to an installation.
That removes manual invention and transcription of first-boot secrets, but does not make an existing installation accept a replacement.
Also distinguish read-only retrieval from `secretspec check`, which can prompt for or store missing values; do not treat it as a harmless presence-only check.

Shape when picked up: recipes that mint first-boot secrets need an accept-supplied-value path; the external supplier resolves generation before invoking Cloudify and supplies the result through the environment.
The value's name, creator, and destination must be known before execution, but a declaration is not proof of storage or successful application.
Import existing installations' current secrets rather than generating replacements during adoption.
Deleting a provider entry and generating a new value does not rotate a running application; rotation needs an explicit package operation that updates the application and provider consistently.
Preconditions: validate each recipe's supply and rotation behavior and the selected secretspec generation command.
External generation needs no Cloudify secret-manager integration under Secrets enter through the environment (ADR-037).
The generation and optional guest-secret-return UX stays deferred until classification, required-secret preflight, and wrapper replay are settled; recording provider locations is not an MVP requirement.

## secretspec serve: replay resolves secrets on the target machine, values never leave it (Rachid, 2026-10-13)

Environment-only secrets (ADR-037) receives values from an external wrapper on the controller and forwards them to the target.
A replay from another machine needs an external supplier there, but Cloudify does not synchronize or select its store.
Target-side resolution is optional aware-consumer research outside the MVP, not a prerequisite of the wrapper model.

`secretspec serve` is secretspec's aware-consumer protocol (versioned
message exchange over stdio): a program pins one manifest/profile/scope
once, then asks for secrets by name at the moment of need. Documented gains
that map onto cloudify: least access (only declared names, pinned scope),
values deliverable as temporary files released at session close, prompts
flowing back to the client, and REMOTE RESOLUTION OVER SSH - a deploy tool
asks the TARGET machine's resolver so values never leave the target.
Caveat from the field guide: no coding agent speaks this protocol today;
it is plumbing for tools that embed secretspec.

Shape when picked up: compare a target-side aware consumer with the external wrapper contract before adding protocol support to Cloudify.
An aware deployment could send names rather than values and resolve them at recipe time, with reason/audit handling.
This would change the environment-only boundary and needs its own decision; there is no existing Cloudify CLI resolution backend to extend in the MVP.
Preconditions: validate serve protocol stability and the target-side secretspec installation.
This optional aware-consumer work is outside the environment-only MVP (Secrets enter through the environment, ADR-037).
A second controller does not require it if its external wrapper can already supply the required environment.

## Simpler uppercase target variables (2026-10-17, discussion)

- [ ] Compare the proposed convention `targets: GUEST, GATEWAY`, invocation `--target GATEWAY=cloudstation:`, and direct runbook variable `$GATEWAY` with today's prefixed `TARGET_GATEWAY` convention.
- **Why:** the same uppercase name at declaration, binding, and use removes case conversion and a redundant prefix from the user's mental model.
- **How:** require uppercase target names and test parsing, environment export, snapshots, replay, and migration of shipped runbooks together.
  Check collisions with runbook inputs and shell/framework variables such as `PATH` before choosing the safety rule; do not overwrite the command environment accidentally.
  Keep current syntax until an explicit contract change is approved.

## Lower-ceremony single-target and targetless runbooks (2026-10-17, discussion)

- [ ] Revisit whether a single-target runbook needs an explicit target name/binding, and whether controller-only runbooks may have no targets.
- **Why:** require names and bindings only when they resolve real ambiguity, not by ceremony.
- **How:** compare the current explicit-target convention with possible single-target shorthand.
  Decide where a genuinely targetless application's current record belongs, how inventory-only recovery works, and how the manifest's required bindings change before enabling it.
  No implicit localhost or target fallback is introduced by this entry.

## Declaration semantics flip (proposed 2026-10-17, needs a pkg sweep)

- [ ] Reorder `.remote-vars` kinds: `NAME=value` optional with default `value`; `NAME=` required with no default; bare `NAME` optional.
  Intuition: `=` demands a value; a bare mention is informational.
- **Why:** today bare `NAME` is required and `NAME=` optional; the two `=` shapes feel inverted.
- **Cost:** a sweep of every pkg declaration plus preflight, masking and tests; a contract change on the declaration enumerator (fragile-surface gate, Rachid's go).
- **Runbooks:** `inputs:` is a bare comma list with no `=` form; required-vs-optional inputs need their own syntax decision (suffix, marker, or keep bare-required for runbooks only) before the flip lands.
- Nothing changes until the sweep plan exists.

## Value ladder: retire per-deployment values; defaults vocabulary (agreed 2026-10-17, ADR draft on go)

- [ ] **Retire** the per-deployment desired-input file and its ladder rung (`~/.config/cloudify/deployments/<app>/<flavor>/<name>/values.yaml`).
  Remaining rungs are all defaults, weakest first: recipe default < global defaults (`remote-vars.yaml`) < package defaults (`pkgs/<pkg>.yaml`) < application defaults (`apps/<app>/defaults.yaml`) < application-flavor defaults (`apps/<app>/<flavor>/defaults.yaml`) < environment.
- **User-forced mark:** when the environment supplies a value at apply time, the ivps inventory record marks that applied value user-forced (Rachid: the mark lives in ivps inventory state, not cloudify side).
  Reconfigure resolves: environment > applied user-forced values > file defaults > recipe default.
  Non-forced applied values never seed; their default re-supplies, and a deleted default entry is honored (the rule of Reconfigure seeds from applied set values, ADR-030, with one bit instead of full source labels).
  `deployment unset` removes the mark so defaults govern again.
- **Vocabulary:** files hold defaults; the environment supplies values; inventory records applied values.
  Except the environment and the forced bit, every source is a default with a priority, not a value.
  The stored "desired inputs" concept disappears.
- **Bonus:** add application-level defaults beside flavor-level defaults; the app-level file is weaker, the flavor-level file wins on collision (more specific wins).
- **Migration:** the only live per-deployment file is octop's `values.yaml`, already mirrored in its inventory record.
- **Secretspec profile convention (settled 2026-10-17):** one profile per named deployment, spelled `app:flavor:name` (identity rules forbid colons inside components, so the spelling is unambiguous; colons are legal in filenames and quoted TOML keys). Slash or hyphen spellings are rejected (nesting/ambiguity). `_direct` buckets get no profile convention.
- Drafted as Defaults ladder, the user-forced bit, and one failure word (ADR-038): retires the input-store clause of One dispatch context (ADR-022) point 2 and the desired-inputs half of Deployment-first inventory (ADR-026) point 8, narrows ADR-030's source labels to the forced bit, and sets `failed` as the one failure word; implementation after specification convergence.

## Inventory recovery compliance bugs and lean package records (ADR-036, 2026-10-17)

- [ ] **Required repair, not a new feature:** implement Inventory owns current state (ADR-036) after remaining specification gaps close.
  Current cloud state must be reconstructible from ivps inventory with required secrets supplied through the new invocation's environment.
  History is not required for current-state recovery.
- **Why:** current manifest rebuilding and some inventory updates require local events; target bindings live outside the package records; adopted records and reserved step ids cannot reliably recover targets from a runbook step.
  The manifest is a cache, not the only home of a binding.
- **How:** preserve the target-to-host association and every required applied setting in inventory.
  Use a valid manifest when present; rebuild it from inventory when missing, corrupt, or out of date.
  **Trigger (settled 2026-10-17):** rebuild on read when the manifest is missing or corrupt, or when any record's `revision` exceeds the manifest's cached high-water mark; keep the explicit rebuild command for force.
  Test a fresh controller holding only runbooks/recipes, synced inventory, and externally supplied secret environment variables, with no local manifests, runs, events, desired-input files, or secret-manager dependency in Cloudify.
  Include adopted deployments, dependencies, single-target and multi-target runbooks, and incomplete operations.
- **Record shape:** review path-derived identity fields duplicated inside package records.
  Prefer reading identities from the inventory path and parent identity records rather than storing independent copies; preserve the target name because the path does not encode it.
  Events still need identities in their bodies because their filenames do not encode deployment or package identity.
  Candidate lean shape (not agreed yet): root-level scalar settings; `****` marking a remembered secret name (never a value, and only on classified secret names); `failed: <phase>` naming the phase of the last failed operation, cleared only by a successful install or reconfigure, so a passing read-only verify cannot clear it; keep both `version` and `revision` (Rachid, 2026-10-17).
  A rebuilt manifest derives its word from inventory alone and stores none of its own: settings present -> `installed`; failure marker -> `failed`; neither -> no word.
  Inventory therefore records no status beyond the failure marker; `installed`/`failed` on a rebuild are derivations, not stored facts.
  `failed` is the one failure word everywhere, replacing `degraded` (Rachid, 2026-10-17); adopted deployments rebuild to `installed`.
  Replace detailed health/last-attempt data only after that minimal marker is agreed, covering a failed first installation (marker present, no settings).
  Per-value provenance shrinks to the one user-forced bit living beside the applied value in the inventory record (Value ladder entry above); Reconfigure seeds from applied set values (ADR-030) keeps its rule with that bit instead of full source labels.
  Secret-name-only records cannot prove equal credentials for shared installations; decide a conservative sharing rule instead of silently removing the guard.
  Schema changes, event reconstruction, and moved-directory behavior need an explicit design before implementation.
- **Replay default (agreed 2026-10-17):** `deployment replay` without `--at` converges current state from ivps inventory; `--at <run>` time-travels that snapshot's ordinary settings.
  Secrets always come from the current environment (Secrets enter through the environment, ADR-037).
  The current newest-snapshot default is a compliance item to fix with this repair.
- **Related drift (settled 2026-10-17, implement ADR-031):** unnamed `app run` matches a proven-identical deployment (bindings + non-secret scalars + `****` names), creates the first with a generated name, and refuses ambiguity naming the candidates; the current literal-`default` selection is the compliance bug.
  Use explicit semantic names anyway while the mismatch remains.

## Secret classification without mandatory new package syntax (settled 2026-10-17)

**Settled (Rachid):** classification = uppercase suffix (`_PASSWORD|_SECRET|_TOKEN|_KEY`, end of name) OR the existing explicit `secret NAME` marker (already parsed by the current code, used by pkg/affine). Mappings are secret when either side matches. Sweep every `pkg/*/.remote-vars` and runbook `inputs:` at implementation; rename outliers deliberately. Never preflight-demand secrets: a recipe/verify hook failing for a missing secret fails loudly, naming it and pointing at the wrapper (graceful, option c).

- [ ] **What:** implement the settled rule above.
  Simple MVP package classification (ADR-035) is superseded at implementation by this settlement; its body stays as history.
- **Why:** name matching can miss a secret such as `LICENSE` or classify a public key as secret, while mandatory parallel declarations can create clerical drift.
  Cloudify must know secret status before resolving, forwarding, capturing, or snapshotting a value.
- **How:** settle a simple naming rule shared by package variables and runbook inputs, preserving classification through mappings.
  The proposed uppercase `_PASSWORD`/`_SECRET` suffix rule misses existing `K3S_TOKEN`; discuss `_TOKEN`/`_KEY` suffixes, explicit exceptions, or a deliberate package-interface rename before narrowing classification.
  Secretspec declarations are external to the environment-only MVP, not a runtime classification source for Cloudify.
  A runbook input has no implemented secret marker today; classification is not carried through its mappings.
  Cover one secret mapped to differently named package variables, optional inputs, unmarked names, explicit references, and applications with no packages.
  Preserve secret status and original input identity through mappings.
  Treat unknown-content detection as a limit, not a promise to discover arbitrary mislabeled secrets.
- **Boundary:** exact suffixes, optional-secret behavior, and runbook propagation remain to be settled; do not silently drop the protection retained by Simple package secret classification (ADR-035).
  More elaborate explicit syntax or metadata belongs to later discussion, not a prerequisite of the environment-only MVP.

## Optional secretspec-aware UX (post-MVP, 2026-10-17)

- [ ] **What:** revisit a launcher or Cloudify integration only if the normal external wrapper proves too cumbersome.
  Secrets enter through the environment (ADR-037) deliberately keeps Cloudify unaware of secretspec for the MVP.
- **Why:** the wrapper's profile selection and Cloudify's deployment selection may repeat related information; users may later want one entry point, per-name retrieval, or simpler declaration setup.
  This is a UX improvement, not a requirement for first install, replay, inventory recovery, or changing external providers.
- **How:** first compare a thin external launcher with a built-in aware consumer.
  If awareness is justified, discuss defaults and any Cloudify-wide/runbook override hierarchy then, not as speculative MVP settings.
  Keep ordinary environment injection working without secretspec.
  Explicitly decide whether awareness introduces stored manager addresses and how historical replay would interpret them; do not silently revive the superseded capture design.
- **Boundary:** no automatic store/fetch interface, manager-selection config, capture policy file, mode/key persistence, or file-provider allowlist belongs to the environment-only MVP.

## Safe run snapshots and environment-only replay (revised 2026-10-17)

- [ ] **What:** implement Secrets enter through the environment (ADR-037): snapshot ordinary settings and secret names, never secret values, digests, or provider locations.
  **Record shape (settled 2026-10-17):** root scalars; `****` for classified secret names; root `user_forced` array; `failed: true` (cleared only by a successful install or reconfigure; a passing verify never clears it); version; revision; target. Multiline values are native JSON strings. Demanded replay names derive from the runbook's `inputs:`/`map:`; a bare package dispatch demands its own variable name.
- **Why:** current snapshots can contain plaintext input values and step outputs.
  They remain local and unsafe for now; warnings and the ban on Git/shared or unencrypted backup still apply.
- **How:** retain secret-name markers so replay does not confuse an omitted value with an ordinary default.
  Replay restores ordinary settings and validates required secrets from the current environment after application mappings.
  It must not overwrite wrapper-supplied values with snapshot literals, empty placeholders, or values from current inventory.
  Persist the application-input name where needed, so a wrapper supplying `RDP_PASSWORD` is not incorrectly required to export every mapped package alias.
  Missing required supply fails before mutation and names the missing variables; Cloudify does not call a backend or know why an external provider failed.
  Prevent automatic step-output persistence from bypassing secret handling.
- **Tests:** caller omits a required secret; wrapper supplies a rotated value; provider changes outside Cloudify; one input maps to several package names; ordinary recorded settings differ from today's defaults; a run fails before its first successful apply.
- **Boundary:** this supersedes the earlier provider-aware snapshot proposal.
  Historical execution uses newly supplied secrets, not proof that the old credential still exists or has the same identity.
  No historical-secret versioning or historical-leak cleanup is required.

## Value-containing base64 references and insecure capture (2026-10-16)

- [ ] Remove value-containing `@base64:` secret references or require explicit insecure consent before recording them as publishable references.
  Encoding a value does not make it a secret location.
  **Settled (2026-10-17):** base64 stays strictly as a file-store multiline transport, never classified as a secret reference; inventory records the decoded scalar as an ordinary value.
- The current backend also implements multiline file-store values, so design a distinct literal transport and migrate its callers before removing it.
  Preserve exact multiline bytes and escaping; do not conflate this backend with private dispatch-context encoding.
- Under the environment-only MVP, classified secrets are not captured as literals or references at all.
  The current multiline encoding must not bypass that rule or be mistaken for a publishable backend location.
  Optional future insecure capture would require a separate explicit decision; it is not a normal MVP mode.
  No runtime change or historical-leak cleanup is authorized by this entry.
