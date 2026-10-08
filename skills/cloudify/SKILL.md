---
name: cloudify
description: "Provision software on Ubuntu/Debian hosts with the `cloudify` CLI. Use when installing, uninstalling or verifying packages on a host or fleet, managing the inventory, or using vars/deployments. For authoring recipes see cloudify-pkg-dev, for changing cloudify itself see cloudify-dev."
---

# Cloudify

Bash CLI for installing packages on Ubuntu/Debian, locally or over SSH.
`cloudify packages` lists packages; `cloudify packages show <pkg>` prints a recipe; `cloudify help` lists everything.

## The one rule

`--on <target>` comes BEFORE `install`/`uninstall`:

```bash
cloudify --on srv install bat      # correct
cloudify install bat --on srv      # runs locally, ignores --on
```

Target grammar: `X` (must exist; node or instance), `X:` (a node), `X:Y` (instance Y on
node X), `:Y` (instance Y on the active node - `cloudify node use <node>`, else the ivps
default). No localhost fallback.

## Commands

```bash
cloudify install|inst|i <pkg...>          # local install (auto-installs @default first)
cloudify --on <host|@tag> install <pkg>   # remote install, parallel across hosts
cloudify uninstall|remove|rem|r <pkg>     # uninstall (needs pkg/uninstall.sh)
cloudify verify <pkg>                     # verify-only (local)
cloudify --on <host> verify <pkg>         # verify-only on a host
cloudify --verify install <pkg>           # verify-only alias
cloudify --no-verify install <pkg>        # skip verify
cloudify --no-defaults install <pkg>      # install only basics (not full @default)
cloudify --clear-data install <pkg>       # wipe persistent data, force reinstall

cloudify packages [@tag|default|show <pkg>]   # list by tag, or print recipe
cloudify hosts [@tag]                          # inventory, filtered by tag
cloudify host <host> / info <host> [ipv4|ipv6] # single-host status / container IP
cloudify <host> shell|-i / exec <host> '<cmd>' # interactive / non-interactive SSH
cloudify launch [remote:]<name> [image]        # create container (default: ubuntu/24.04/cloud)
cloudify delete [remote:]<name>                # delete container
cloudify credentials [remote|github|gitlab] / --check
cloudify hostnames <host> [IP] / cloudify init  # /etc/hosts entry / first-run setup
cloudify node use <node>                       # set the active node (prints the export)
cloudify app run <app>[/<flavor>] [--name <n>] [--target name=addr]  # run its runbook
cloudify deployment replay <id> [--at <run>]   # re-run a recorded run from its snapshot
```

## Deployments & runbooks

- `cloudify deployment list|show|replay|delete <id>`; values via `vars ... --deployment <app>/<flavor>/<name>`.
- A runbook is repo-tracked Markdown (`runbooks/<app>/<flavor>/runbook.md`): front-matter `targets:` (+ optional `inputs:`/`map:`), `bash step=<type>` fences (`launch|install|configure|verify|uninstall|run|human-gate`). `app run` binds targets (`--target name=addr`, else the deployment var `TARGET_<NAME>`), preflights required vars, runs the steps in order (a `human-gate` step pauses), and writes a run snapshot; `deployment replay` re-runs one from its snapshot. See `runbooks/README.md`.
- An install also writes an observation record under the target's ivps node dir; `deployment delete` sweeps it.

## Vars

```bash
cloudify vars set NAME value [--global|--pkg <p>|--deployment <app>/<flavor>/<name>] [--stdin|--file <path>]
cloudify vars show|list [--json] NAME [scope] [--reveal] [--resolve]
cloudify vars delete|unset NAME [scope]
cloudify vars declared <pkg> [--sources]
```
Precedence: recipe default < global < package < deployment < caller env.
`show`/`list` mask `PASSWORD|TOKEN|SECRET|KEY` unless `--reveal`; `--resolve` decodes a `@<backend>:<locator>` reference.
Secrets: prefer `--stdin`. A value may be `@base64:<b64>` (multi-line) or `@<backend>:<locator>` (`@@` escapes a literal `@`).

## Logging (baked in, never invent logs)

Every run auto-logs; on failure it prints `Log: /tmp/cloudify/logs/<ts>.log` (remote runs stream + tee the same). stdout IS the live stream: a foreground run needs no redirect.

- Detach a long run: `setsid cloudify ... &`, then `tail` the newest `/tmp/cloudify/logs/<ts>.log` (`ls -t /tmp/cloudify/logs/*.log | head -1`). Never discard output (`>/dev/null`) and never write your own log/progress file.
- Read raw: plain `tail -N` with no sed/grep pipes; every poll prints fresh content.
- `DEBUG=true` (forwarded) traces each command; `CLOUDIFY_LOG_LEVEL` filters verbosity. Verify retries emit a heartbeat every ~20s.

## Key facts

- Remote hosts pull from GitHub, not your checkout.
- `@default` packages auto-install before any requested package. Install verifies by default (`verify.sh` opt-in, deps deep-verified).
- `CLOUDIFY_FORCE` = explicit installs; unset for `pkg_depends` pulls. `--clear-data` implies FORCE and wipes persistent data.
- `uninstall` runs the package's optional `uninstall.sh`. No leg = clear error, nothing changed, non-zero exit. Dependencies are never removed; verify is not run.

## Credentials & secrets

- System secrets: `~/.config/cloudify/credentials` (0600), via `cloudify credentials <section>`.
- Forwarding: only vars on the envsubst allow-list reach a host; others are inert.
- Git auth on hosts needs a TOKEN (`CLOUDIFY_GITHUB_READONLY_TOKEN`); GitHub rejects passwords.
- Package secrets: `pkg/<name>/.remote-vars` declares names; values come from the caller env.

## Security

- Payload travels on stdin, never argv: no secret in either process list.
- At rest `~/.config/cloudify/` is 0700/0600; prefer `@<backend>:<locator>` over a literal.
- Masking: `vars show|list` mask secret-looking names unless `--reveal`. Never echo a secret.
- Vault: operator-side (default) ships plaintext; host-side ships the reference. The host always holds plaintext to use it.
- Tailnet access is least-privilege: scope ACL grants to the smallest set. If only a few devices need a port, create per-role tags (`rdp-client`/`rdp-server`) and grant between them; never make one shared tag reach itself (any-to-any).
- Publishing default is in-tailnet (`ivps expose-service` / tailscale routes): the ACL is the security boundary and stays the only one needed. Surface off-tailnet routes (funnel, public DNS, account-relayed tunnels such as T3 Connect) only when off-tailnet access is a real requirement - and state the surface tradeoff (external relay/third party/account credential as the gate) when you propose one. Ruled 2026-10-08 after T3 Connect shipped by default and was torn down same-day.
- URLs and cross-host references use MagicDNS names, never IPs.
