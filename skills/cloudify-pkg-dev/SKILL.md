---
name: cloudify-pkg-dev
description: Use when writing, upgrading or modifying cloudify packages. For using cloudify see cloudify; for the cloudify tool see cloudify-dev.
---

# Authoring a cloudify package

## Constitution

- The bats harness is the completion gate, never the debugger. Prove the change with static checks and a manual run on the target, then run the harness once, at the end. Debugging through a full harness run multiplies the cost of every change.

## Research (before authoring a pkg or runbook)

- Getting-started docs describe happy paths and lie by omission. Follow the official site's links (install, configuration, service/daemon pages) and search (`pi-exa` skill: "<name> install systemd") before designing.
- Read the installer script end to end - flags, mirror logic, prerelease flags, install layout - before curl|bash-ing it.
- Run the vendor's quick-start by hand once in a throwaway container; verify what it actually creates.
- Probe the verify endpoint by hand (`curl`) before writing verify.sh.
- Pre-resolve pinned versions locally (`uv pip install --dry-run "<spec>"`, ecosystem equivalent) before dispatching.
- Size waits and timeouts at 3x the longest observed boot/install time.
- Runbooks: `runbooks/README.md` is the spec - front-matter `targets:` (+ `inputs:`/`map:`), `bash step=` fences, commands from `ivps` and `cloudify` only, every flag validated against the tool's usage output.

## DONOT

- Never convert `curl URL | bash -s -- args` into `bash -c "$(curl URL)" ...`. With `bash -c` the next word becomes `$0`: the script receives `--` as its first argument. Download to a file, run `bash <file> <args>`.
- Never dispatch without `CLOUDIFY_FORCE_UPDATE=true` while iterating. The 30-minute gate silently runs stale code; the only trace is the `checkout v1:` line.
- Never redirect or filter cloudify output (`>/dev/null`, pipes, `rg` on first read), never trust memory over the log. Transcripts are evidence: `/tmp/cloudify/logs/<ts>.log` on the controller, `latest.log` only on hosts (AGENTS.md LOGS).
- Never rerun with a timeout below the last observed duration. After any self-inflicted timeout kill, the next timeout is 3x observed.
- Never inline quotes, pipes or `$()` in `cloudify exec '<cmd>'` - the channel mangles them. Push a script (`ivps push`) and run the file.
- Never `cloudify app run` on a dirty tree - commit the plan first.

## Layout

`pkg/<name>/`:
- `init.sh` required (legacy), or `install.sh` + `configure.sh` (split, ADR-008).
- `.version` required: the package's declared version, one line (e.g. `1.0.0`); bump it when the package meaningfully changes. Framework reads it for the package's `result v1:` line and the inventory; missing/empty/off-charset records the attempt failed. Never probed from the machine - packages are opaque, devs trusted.
- optional `uninstall.sh`, `verify.sh` (`pkg_verify()`), `@default` (empty tag), `#<os>` (platform filter), `.remote-vars`, `README.md`.

Lifecycle: install provisions (create-if-absent, never mutates existing config), configure configures (run phase, converges), uninstall tears down.
No `uninstall.sh` = clear error, nothing changed, non-zero. Dependencies are never removed.

Compose-semantics-first: express service behavior in compose (`healthcheck`, `depends_on: condition: service_healthy`, `restart`, `env_file`, `up -d --wait`), never bash wait loops.

## Recipe API (`lib/package-api.sh`)

```bash
pkg_apt_install <pkg...>            # apt-get install (idempotent via shadow)
pkg_apt_update [--force] / pkg_apt_repository <ppa>   # apt wrappers (idempotent)
pkg_install_release <name> <repo>   # GitHub release download (auto arch)
pkg_depends <pkg...>                # cloudify pkg if exists, else apt fallback
pkg_backup <path> / pkg_restore <path>   # rotated backups (up to 5)
pkg_in_startuprc <line>             # deduped ~/.bashrc append
PKG_DEBUG <msg>                     # debug output (when DEBUG=true)
```

Stateful packages use the install guard:

```bash
pkg_depends <deps>
if <already_installed> && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "Already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi
# ... install ...
```

Recipes run with errexit suspended (sourced inside `if ! ( ... )`): bare failures continue silently. Use explicit `|| die` + postcondition asserts on every failure-prone op; never rely on `set -e`.

## Vars

`.remote-vars` is a declaration mirror, one var per line: `NAME` required, `NAME=default` defaulted (mirror the recipe's `${NAME:-default}`), `NAME=` optional.
It never supplies a value; the recipe default stays runtime truth; keep the two in sync.
`cloudify vars declared <pkg>` prints the kinds (`--sources` adds the source).
Precedence: recipe default < global < package < deployment < caller env.
Secrets via `--stdin`; a value may be `@base64:<b64>` (multi-line) or `@<backend>:<locator>` (`@@` escapes a literal `@`).

## Verify

`verify.sh` defines `pkg_verify()`, sourced in a clean subshell (exported env + on-disk config only, no recipe locals).
Read inputs from env vars or config files, never hardcoded endpoints. Retries to `PKG_VERIFY_TIMEOUT`.
Deep verify runs after every package, including dependencies.

## Testing (TDD at the right level; the harness is acceptance, never the debugger)

Ladder, advance only when the current level is green: L0 `shellcheck` + `bash -n`; L1 a `bash -x` driver sourcing the phase files on the real target (no dispatch); L2 `cloudify --no-verify install`, read cloudify's log; L3 `cloudify verify` with `PKG_VERIFY_TIMEOUT=30`; L4 the bats harness, only as the final gate. Cheap proofs run on the tested container; localhost proves only shell semantics. One hypothesis per red cycle; never relaunch the same run.

### Run
- Scope by blast radius: the smallest set that can catch the change. Never debug with the full suite or E2E.
- Interface: `task test-unit`, `task test-integration:<pkg>`.
- Long runs go in the background; the run streams to `results/<name>.tap`. Poll it with plain `tail`, raw, no grep/sed. Never invent a log or an exit marker.
- Read cloudify's own log live: `/tmp/cloudify/logs/<ts>.log`.
- After a snapshot restore or container launch, wait for SSH/tailnet readiness before asserting.
- E2E once, at the end, on final HEAD. Push before remote tests (hosts pull from GitHub).

### Write
- Every `@test` opens with `rubric "<claim>"`; phases use `subrubric`; actions use `step` (`tests/helpers/report.bash`), timestamped.
- The helper writes to fd 9 when the runner opens it, so lines stream live through bats; otherwise stdout.
- Runner: `bats -T --show-output-of-passing-tests | tee results/<name>.tap`; prints the numbered plan (`1..N` is TAP's plan, not the report).
- Expensive one-time setup in `setup_file` with a readiness wait, never a `@test`.
- No custom logs in tests; `mktemp` for transient captures, print on failure.
- Keep tests focused; delete heavy E2E that duplicates a unit guard plus a lighter integration check.

## Security

- A recipe may persist plaintext only in its own 0600 state files; never write a secret into the repo, never print one.
- A config file a service reads (compose `.env`) may hold a secret; keep it 0600. Cloudify state carries a reference (`@<backend>:<locator>`), not the plaintext.

## References

README.md: "Writing a Package Recipe" + "Verification".
