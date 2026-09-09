# Plan: URGENT surface cleanup (traps 1-7 + decided var/security/lifecycle items)

Source of truth: ROADMAP.md "URGENT" section (all decisions recorded 2026-09-07).
Rule: one feature branch per group below, merged to master before the next branch
starts. Several roadmap entries share a branch when they touch the same surface.
Every branch: gate artifacts (description -> plan -> consent) where lib/router is
touched; tests per branch; `git status` clean + docs (HISTORY/LOGS) at merge.

## Branch 1 - vars internals: five-source helpers + walker + precedence

Scope (ROADMAP: Vars internals + security, Target config model):
- `cloudify_vars_{global,pkg,deployment,env}_read|write`, `cloudify_vars_state_read`
  (replay, read-only) with one naming scheme; collector becomes a thin precedence
  walker replacing `_try_claim`, `_try_claim_env`, `_cloudify_deployment_read_vars`.
- Resolver seam: `_cloudify_resolve_var_value <name> <raw>` (identity today), called
  by every reader; `@backend:locator` reserved, `@@` escape; backends as
  `lib/secrets/*.sh` plugins (no vault shipped).
- Target precedence: recipe default < global < package < deployment < env
  (flips today's remote-vars.yaml=strongest, deployment=weakest).
- Back-compat: bare-name `.remote-vars` files keep working.

Gate: lib/remote.sh + lib/deployments.sh + lib/pkg-config.sh (CRITICAL GATE).
Tests: unit per reader + precedence order + resolver identity/escape; integration
forwarding (package-remote-vars.bats) still green.
Done when: precedence tests pass, remote-vars integration green, no recipe changes needed.

## Branch 2 - CLI actions: verify + uninstall

Scope (ROADMAP traps 4, 3; lifecycle rule):
- `verify` as a first-class action in both contexts (`cloudify --on <host> verify <pkg>`);
  keep `--verify install` alias; clear parser error when trailing words are not packages.
- `uninstall` action: router + phase sourcing; optional `pkg/<name>/uninstall.sh`,
  defined default when absent; `pkg_depends`-style dep handling; verify not run.
- Skill/doc: action vocabulary + uninstall contract.

Gate: router + lib/packages.sh + lib/package-api.sh.
Tests: integration fixture pkg with uninstall.sh (removes markers); remote verify
action; alias still works.
Done when: both actions green on the test container, existing split/verify tests green.

## Branch 3 - security: payload via stdin + skill Security section

Scope (ROADMAP: Vars internals + security):
- Send the remote payload via stdin (`ssh host 'bash -s' < payload`) instead of argv;
  secrets no longer visible in operator or host process lists.
- Skill: Security section (stdin payload; references in cloudify state; masking
  PASSWORD/TOKEN/SECRET/KEY; 0600; no secrets in logs; two vault models + the
  fundamental limit that the host must hold the plaintext).

Gate: lib/remote.sh.
Tests: integration proving a secret does not appear in argv (probe the remote
process table during a slow install) + existing suite green.
Done when: stdin path green, no regression in remote installs.

## Branch 4 - guacamole 3-leg rewrite (reference package)

Scope (ROADMAP trap 3 resolution + lifecycle + compose-semantics-first):
- install.sh provisions only: create-if-absent `.env`/compose, `docker compose up -d
  --wait` with healthchecks, no config mutation, no bash wait loops.
- configure.sh configures: rewrite config, up, converge the DB credential via the
  postgres local socket (`ALTER USER ... PASSWORD`), upsert the connection record.
- uninstall.sh: `docker compose down -v` then remove the project dir.
- Admin default `rbc` -> `guacadmin` (trap 7).
- Evaluate mounting the schema under `/docker-entrypoint-initdb.d` instead of
  docker cp + psql (revisit partial-init detection).

Depends on: branch 2 (uninstall action).
Tests: bats rewritten - install, configure (incl. changed DB password converges),
uninstall removes volumes, FORCE reinstall preserves data.
Done when: bats green, run time <= previous, no compose mechanics duplicated in bash
that compose expresses natively.

## Branch 5 - xfce alignment

Scope: declaration syntax per the pkg-writing standard; neutral defaults; keep
install/configure; optional uninstall.sh (remove packages/user only with explicit
intent; never the home). No behavioral traps to fix beyond alignment.
Tests: existing package-xfce.bats green + declaration reader output.

## Branch 6 - runbooks (a): agent runbooks tree + amnesiac validation

Scope (ROADMAP: Runbooks a):
- Create `runbooks/<app>/<flavor>.md`; first entry = the xfce+guacamole E2E rewritten
  to the rules (commands only, names not values, MagicDNS names, human gate,
  teardown). Move/retire `plans/xfce-guacamole-e2e.md` (plans are not for runbooks).
- Amnesiac test: a fresh agent session, given only the cloudify skill + the runbook
  path, deploys on disposable infra with no hints; every stumble is a runbook defect.
Done when: the amnesiac run completes end to end.

## Branch 7 - state registry (prerequisite for runbooks b)

Scope (ROADMAP: Vars internals + security; state-registry design):
- Per-node slices `$(ivps node path <host>)/deployments/<id>/pkgs/<pkg>/config.yaml`
  keyed (deployment, instance, package); replay input, outside precedence;
  references/hashes for secrets; `ivps delete <host>` cleans the slice.
Gate: lib (write path + replay read), CRITICAL GATE.
Tests: install writes the slice; replay re-applies recorded values only on explicit
re-enactment; deletion cleans up.

## Branch 8 - runbooks (b): `cloudify deployment run`

Scope (ROADMAP: Runbooks b; Idea 3 stays non-urgent):
- Deployment declares roles + typed steps as data (launch/install/configure/verify/
  uninstall/human-gate); addresses by name; step outputs go to the state record;
  preflight validates required vars via `vars declared`; secrets by name only.
Depends on: branches 1-7.
Tests: the xfce+guacamole app runs from a deployment runbook on disposable infra;
generated vs hand-written comparison stays a later (idea 3) exercise.

## Notes

- PLAN.md points at this plan while the cleanup runs.
- The skill gains: pkg-writing var standard + sync rule, compose-semantics-first,
  Security section, MagicDNS-names rule (recorded in ROADMAP).
