# Description: the bash magic pkg/guacamole will run on (written before any pkg code)

Status: written artifact per the CRITICAL GATE (AGENTS.md). Grounded in code read from
`cloudify` (router), `lib/remote.sh`, `lib/shadows/*.sh`, `lib/shadow.sh`, `lib/package-api.sh`,
`lib/pkg-config.sh`, `lib/credentials.sh`, `lib/packages.sh`, `lib/utils.sh`, `lib/deployments.sh`,
`pkg/docker/init.sh`, `pkg/open-webui/init.sh`, `pkg/hermes*`, `pkg/k3s-server/*`,
`pkg/fixture-env/*`, `pkg/fixture-split/*`, `tests/run-integration.sh`, `tests/helpers/integration.bash`,
`~/.config/cloudify/`. Nothing here was inferred from docs alone; where code is ambiguous it is flagged `[AMBIGUOUS]`.

Key files and real locations:

- Router: `/home/rbc/PROJECTS/PROD/cloudify/cloudify`
- `lib/remote.sh` — payload template `cloudify_remote_payload_template()` (lines 20-78), var collector `_cloudify_pkg_remote_vars()` (98-230), executor `cloudify_remote_sync()` (246-321)
- `lib/package-api.sh` — `pkg_depends` (417-468), `_cloudify_run_verify` (336-365), `_cloudify_source_pkg_phases` (370-385), `cloudify_package_verify_path` (319-329)
- `lib/packages.sh` — recipe path resolution `cloudify_package_recipe_path()` (ADR-008: `install.sh` preferred, `init.sh` legacy fallback)
- `lib/pkg-config.sh` — `_cloudify_load_yaml_vars()` flat-YAML → exported env
- Config home: `~/.config/cloudify/` (chmod 700); per-pkg yaml dir `~/.config/cloudify/pkgs/`; always-forward `~/.config/cloudify/remote-vars.yaml` (currently ABSENT on this host); credentials file `~/.config/cloudify/credentials`
- Existing pkg yamls on this host: `affine.yaml`, `hermes-dashboard.yaml`, `hermes-openwebui.yaml`, `open-webui.yaml`
- Deployments: `~/.config/cloudify/deployments/<id>/config.yaml` (ADR-011)

---

## 1. End-to-end trace: `cloudify --on <host> install guacamole`

### 1.1 Router parse (local shell)

`cloudify` main() (router) parses `--on <host> install guacamole`:

1. `--on` block (router `case --on)`) collects `<host>` into `hosts`. Actions and flags end the host list.
2. `install` sets `packages="--install guacamole"`; a reserved word or end-of-args calls `_cloudify_dispatch install "<host>" "--install guacamole"`.
3. `_cloudify_dispatch` (router) calls `_cloudify_require_remote_creds` (dies if `CLOUDIFY_REMOTE_PWD` unset; `CLOUDIFY_REMOTE_USER` defaults to `whoami`), then for each host: `export CLOUDIFY_FORCE=true` (explicit dispatch marker), then `cloudify_remote "$host" "--install guacamole"`.
4. `cloudify_remote` (remote.sh:240) backgrounds `cloudify_remote_sync` and records the PID/host for the final wait loop. Exit codes land in `$CLOUDIFY_TMP/<host>.exit`; all SSH output is tee'd to `$CLOUDIFY_TMP/logs/<timestamp>.log`.

CLOUDIFY_FORCE is what distinguishes an explicit `cloudify install X` from a dependency pull via `pkg_depends X` — this is the entire install-guard contract (see 3.7).

### 1.2 Payload construction (local shell, in `cloudify_remote_sync`, remote.sh:246+)

**Step A — var collection.** `_cloudify_pkg_remote_vars "--install guacamole"` (remote.sh:98) runs in the PARENT shell (its `export`s must survive for envsubst) and writes claimed var names, one per line, to a temp list. Walk order and priority (comment in code, lines 85-96):

1. Always-forward file `~/.config/cloudify/remote-vars.yaml` first — highest priority (claims first; first-write-wins).
2. Named packages right-to-left (last CLI arg wins).
3. For each package: `.remote-vars` env claims (`_try_claim_env`), then per-pkg yaml `~/.config/cloudify/pkgs/<pkg>.yaml` (`_try_claim`, back-compat), then recursive `pkg_depends` walk via `grep '^[[:space:]]*pkg_depends ' "$recipe"` (regex-scanned, not executed), parents before deps.
4. Deployment vars (`CLOUDIFY_DEPLOYMENT` set) last — lowest priority.

Claiming mechanics: a temp file `TMPFILE=$(mktemp /tmp/cloudify-pkg-vars-XXXXXX)` is the claim ledger. `grep -qx "$key" "$TMPFILE" && continue` = already claimed; otherwise the name is appended and the value `export`ed. A `trap ... RETURN` cleans the temp file only when `_cloudify_pkg_remote_vars` itself returns (functrace-safe for bats).

- `_try_claim` (yaml): reads `KEY: value` lines (regex `^[A-Z_][A-Z0-9_]*:`), trims whitespace + surrounding single/double quotes, `export KEY=value`, records name. Missing file → no-op.
- `_try_claim_env` (.remote-vars): each non-comment line is a NAME (regex `^[A-Z_][A-Z0-9_]*$`). If `${!key}` non-empty in caller env → `export "$key"="${!key}"` — env OVERRIDES any disk-claimed value of the same name — and claims if not claimed. If unset → `log_warn "Var $key (declared in pkg $pkg .remote-vars) is unset in caller env — not forwarded."` (nothing empty is forwarded by this path).

So a secret for guacamole can arrive two ways, both ending as a caller-side exported variable when envsubst runs:
- `pkg/guacamole/.remote-vars` listing the NAME (in repo) + the caller exporting the VALUE (`GUACAMOLE_ADMIN_PASSWORD=x cloudify --on host install guacamole`), or
- `~/.config/cloudify/pkgs/guacamole.yaml` with `GUACAMOLE_ADMIN_PASSWORD: "x"` (name+value on disk, chmod 600).

Both are parallel-safe: values never touch a shared file (the only shared file is the claim ledger of NAMES).

**Step B — template body extraction.** The remote payload body is the FUNCTION BODY of `cloudify_remote_payload_template` (remote.sh:20), extracted literally:

```bash
cloudify_remote_payload=$(declare -f cloudify_remote_payload_template | tail -n +3 | head -n -1)
```

`tail -n +3` strips `cloudify_remote_payload_template ()` and `{`; `head -n -1` strips the closing `}`. Result is the function's statements as literal text (leading 4-space indent kept). Real body excerpts (remote.sh:24-76):

```bash
    export CLOUDIFY_IS_LOCAL=false
    export CLOUDIFY_DISABLE_COLORS='$CLOUDIFY_DISABLE_COLORS'
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    export CLOUDIFY_SKIPCREDENTIALS=true
    export CLOUDIFY_LOCAL_USER='$CLOUDIFY_REMOTE_USER'
    export CLOUDIFY_LOCAL_PWD='$CLOUDIFY_REMOTE_PWD'
    export CLOUDIFY_HOSTPWD='$CLOUDIFY_REMOTE_PWD'
    export CLOUDIFY_GITHUBUSER='$CLOUDIFY_GITHUBUSER'
    export CLOUDIFY_GITHUB_READONLY_TOKEN='$CLOUDIFY_GITHUB_READONLY_TOKEN'
    export RESTIC_PASSWORD='$RESTIC_PASSWORD'
    export CLOUDIFY_CLEAR_DATA='$CLOUDIFY_CLEAR_DATA'
    export CLOUDIFY_FORCE='$CLOUDIFY_FORCE'
    export CLOUDIFY_NO_VERIFY='$CLOUDIFY_NO_VERIFY'
    export PKG_VERIFY_TIMEOUT='$PKG_VERIFY_TIMEOUT'
    : _CLOUDIFY_PKG_EXPORTS_
    ...
    exec > >(tee -a "$CLOUDIFY_LOG_FILE") 2>&1 </dev/null
    :
```

**Step C — pkg export injection.** For each claimed var name the sync function builds two strings (remote.sh:275-282):

```bash
pkg_envsubst="$pkg_envsubst \$$var"
pkg_exports="${pkg_exports}"$'\n'"    export $var='\$$var'"
```

For `GUACAMOLE_ADMIN_PASSWORD` that is an envsubst allow-list entry `$GUACAMOLE_ADMIN_PASSWORD` and an injected line `    export GUACAMOLE_ADMIN_PASSWORD='$GUACAMOLE_ADMIN_PASSWORD'`. The injected lines replace the literal placeholder `_CLOUDIFY_PKG_EXPORTS_` (string substitution, remote.sh:284).

**Step D — envsubst with explicit allow-list** (remote.sh:286-290). Only the listed vars are substituted; everything else in the payload survives verbatim to remote execution:

```bash
cloudify_remote_payload=$(envsubst \
    "\$CLOUDIFY_DISABLE_COLORS \$DEBUG \$CLOUDIFY_LOG_LEVEL \$CLOUDIFY_NO_DEFAULTS \
     \$CLOUDIFY_CLEAR_DATA \$CLOUDIFY_FORCE \$CLOUDIFY_NO_VERIFY \$PKG_VERIFY_TIMEOUT \
     \$CLOUDIFY_FORCE_UPDATE \$CLOUDIFY_UPDATE_DELAY \$CLOUDIFY_REMOTE_USER \$CLOUDIFY_REMOTE_PWD \
     \$CLOUDIFY_GITHUBUSER \$CLOUDIFY_GITHUBPWD \$CLOUDIFY_GITHUB_READONLY_TOKEN \$CLOUDIFY_GITLABUSER \
     \$CLOUDIFY_GITLABPWD \$CLOUDIFY_RCLONE_REMOTE ... \$RESTIC_PASSWORD \$CLOUDIFY_BOOTSTRAP_URL \
     \$CLOUDIFY_LOG_BASENAME${pkg_envsubst}" <<< "$cloudify_remote_payload")
```

envsubst does pure text substitution of the `$VAR` tokens present in the allow-list. Because the placeholder tokens sit inside SINGLE QUOTES in the template (`'$CLOUDIFY_REMOTE_PWD'`), the substituted value is left wrapped in single quotes in the final payload → the remote shell parses the value as one literal string (spaces, `$`, `!` inert). Verified empirically:

```
$ printf "    export CLOUDIFY_HOSTPWD='\$CLOUDIFY_REMOTE_PWD'\n" \
  | CLOUDIFY_REMOTE_PWD='pa ssword' envsubst '$CLOUDIFY_REMOTE_PWD'
    export CLOUDIFY_HOSTPWD='pa ssword'
```

Tokens NOT allow-listed survive and are expanded by the REMOTE shell at runtime: `$HOME` (in `export CLOUDIFY_LOCAL_BIN="$HOME/.local/bin"` and `find $HOME/cloudify/.#last_update ...`), `$(date +%Y%m%d-%H%M%S)`, `$(curl ...)`, and the appended `$*` command tail. That is the deliberate split: secrets are baked in locally (inert, single-quoted); only safe structural references are left for remote expansion.

**Step E — command tail and transport** (remote.sh:292-321). The remote command is appended after the template's trailing no-op `:` (the HACK comment: the `:` keeps `; cloudify $*` on its own line after the template body ends):

```bash
cloudify_remote_payload="$cloudify_remote_payload; cloudify $*"
```

For us: `...\n    :; cloudify --install guacamole` — note the remote router receives `--install guacamole` as its argv. Then:

```bash
ssh -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" -o "ConnectTimeout=10" \
    "$CLOUDIFY_REMOTE_USER@$host" "$cloudify_remote_payload" 2>&1 | ...
```

The whole payload is one ssh command string; the remote login shell parses it: exports run, `CLOUDIFY_IS_LOCAL=false` is set, `cloudify init` runs (bootstrap: `bash -c "$(curl -sL '$CLOUDIFY_BOOTSTRAP_URL')"` clones/pulls `~/cloudify` from GitHub when the `.#last_update` marker is older than `CLOUDIFY_UPDATE_DELAY` minutes), then `exec > >(tee -a "$CLOUDIFY_LOG_FILE") 2>&1 </dev/null` redirects the rest of the session output to the remote log file AND the SSH channel, and the trailing `cloudify --install guacamole` executes the real install on the host.

**REMOTE HOSTS RUN CODE FROM GITHUB, NOT THE LOCAL CHECKOUT.** The recipe that runs remotely is the one pushed to `github.com/rachidbch/cloudify` master. Push before any `--on` test.

### 1.3 Remote execution (host side)

`cloudify --install guacamole` parses again (remote): `_cloudify_dispatch` runs with `hosts=localhost`, calls `_cloudify_execute_package_action install guacamole`:

1. `@default` packages install first (unless `CLOUDIFY_NO_DEFAULTS=true`): `cloudify_list_default_packages` = pkgs tagged `#ubuntu @default`, then `cloudify_install_package $defaults`. Failure here aborts before the requested package. The payload template set `CLOUDIFY_FORCE` via env — but see 3.7: `_cloudify_execute_package_action` re-`export CLOUDIFY_FORCE=true` only inside its subshell for the explicit pkg; default pkg installs run without FORCE.
2. Explicit dispatch: `( export CLOUDIFY_FORCE=true; cloudify_install_package guacamole ) &` → `pkg_depends guacamole` (package-api.sh:417).
3. `pkg_depends guacamole`: `_CLOUDIFY_PKG_DEPTH` starts at 0 (explicit → FORCE visible). `cloudify_package_recipe_path guacamole` resolves a recipe file. For a fresh `pkg/guacamole/` with NO `install.sh`, resolution tries (packages.sh:135-166): `24.04.ubuntu.Debian.ubuntu.init.sh`? no → `ubuntu.init.sh` (os-specific: `$CLOUDIFY_DIR/pkg/<pkg>/<os>.<filename>`)? no → plain `init.sh`. So the ONLY required file is `pkg/guacamole/init.sh`. Adding `install.sh` makes the pkg a SPLIT pkg: `_cloudify_source_pkg_phases` sources install.sh then, if `configure.sh` exists, configure.sh (ADR-008). Recipe runs with `set -Eeuo pipefail` inherited (router line 12).
4. Inside the recipe: `pkg_depends docker` (dependency) → recursion: depth becomes 1, runs docker's recipe in a subshell with `CLOUDIFY_FORCE` and `CLOUDIFY_CLEAR_DATA` UNSET (`unset CLOUDIFY_FORCE; unset CLOUDIFY_CLEAR_DATA` — package-api.sh:434-436) so the dep's install guard sees a dependency pull, not an explicit reinstall.
5. After EVERY package (recipe or native apt fallback), unless `CLOUDIFY_NO_VERIFY=true`: `_cloudify_run_verify <pkg>` (deep verify, see section 4). Verify failure is recorded and the loop continues; `pkg_depends` returns 1 if any package failed. A verify failure of docker would fail the whole guacamole install.
6. `cloudify_print_done`; exit status propagates: recipe subshell → `cloudify_install_package` → remote `cloudify` exit → ssh exit → `$CLOUDIFY_TMP/<host>.exit` → final router wait reports `OK`/`FAILED (exit N)` and the log path.

Note the recipe is SOURCED, not exec'd: `_cloudify_source_pkg_phases` runs `source "$recipe_path"` inside the caller's subshell (package-api.sh:370-385). A recipe may `return 0` early (install guards do exactly this). `die` exits the subshell with code 1/2, contained by the `if ! ( ... )` in `pkg_depends`.

### 1.4 Illustrative final payload (what ssh actually runs — mechanism verified above)

```bash
    export CLOUDIFY_IS_LOCAL=false
    export CLOUDIFY_HOSTPWD='<remote pwd, single-quoted inert>'
    export CLOUDIFY_FORCE='true'
    export PKG_VERIFY_TIMEOUT='120'
    export GUACAMOLE_ADMIN_PASSWORD='<baked value>'
    export GUACAMOLE_ADMIN_USER='<baked value>'
    ...
    cloudify init
    exec > >(tee -a /tmp/cloudify/logs/<ts>.log) 2>&1 </dev/null
    :; cloudify --install guacamole
```

---

## 2. Shadow functions (`lib/shadows/*.sh`, loaded by `lib/shadow.sh`)

`lib/shadow.sh` sources every `lib/shadows/*.sh` at router startup. Each defines a function with the same name as the command it replaces; `command <name>` inside calls the real binary. Shadows are active when recipes run, locally and remotely. Recipe-local shadow call ORDER matters: shadow `sudo` calls REAL `sudo`; shadow `apt-get` calls shadow `sudo` which calls real `sudo`; shadow `add-apt-repository` calls shadow `sudo` + shadow `apt-get`. New recipes must stay inside this layering (never `command sudo` / `command apt-get` directly, except where the libs themselves do).

### 2.1 `sudo()` — password injection (sudo.sh)

Purpose: sudo needs the password on stdin (`-S`), but recipe stdin may be a pipe or /dev/null.

1. `cloudify_get_password password user host` copies `CLOUDIFY_HOSTPWD` (single source of truth; remote = `CLOUDIFY_REMOTE_PWD` mapped by the payload template, local = `CLOUDIFY_LOCAL_PWD` mapped in router main). Empty → `die "Password not set..."`.
2. Re-quotes tricky argv: `add-apt-repository` (single-quotes the repo arg), `sed` (single-quotes the expression), `find` (escapes trailing `;`). NOTE: the find branch contains a stray `echo dealing with find` on stdout — leftover debug output.
3. stdin detection: TTY → no pipe args; named pipe `/dev/stdin` → `pipeargs="$(cat -)"`; `/dev/null` → empty; else (heredoc/redirect) → `cat -`.
4. If no piped input: `sudocmd="$lineargs"`; else `sudocmd="echo '$pipeargs' | $lineargs"` (the piped bytes are replayed INSIDE a `bash -c` string — single quotes around the whole payload).
5. If `sudocmd` ≤ 10000 chars: `command sudo -kS -p "" bash -c "$sudocmd" <<<"$password"`. The herestring frees stdin for the password while `-kS` forces re-auth and reads stdin.
6. > 10000 chars: writes the piped data to a mktemp file and runs `command sudo -p " " -kS "$lineargs" "$tfile" <<<"$password"` — the temp file is passed as a TRAILING ARGUMENT.

Invariants recipes rely on: `CLOUDIFY_HOSTPWD` is set; the command string fits the single-quote re-echo (no `'` inside piped data/args); stdin must be free when sudo itself runs (shadow frees it only when it can rearrange); commands whose semantics change when a file arg is appended (>10k path) must not be piped into sudo.

### 2.2 `apt-get()` and `apt()` (apt-get.sh)

- `install`: pre-pass checks `dpkg -l` (`_cloudify_pkg_installed`), skips installed pkgs, strips flags, refreshes cache only if something is genuinely missing AND `_cloudify_apt_cache_stale` (>60 min). Then per-pkg idempotent install via `sudo apt-get -qq install <pkg> -y`. `_cloudify_deb_to_pkgname` maps a `.deb` path to its basename for the check.
- `update`: `--force` or stale → `sudo apt-get -qq update`.
- `remove|purge` and everything else: pass through to `sudo apt-get "$@"`.
- `apt()` = thin alias to the apt-get shadow.

Invariants: recipes call `apt-get` (or `pkg_apt_install`, thin wrapper at package-api.sh) and NEVER `sudo apt-get` directly (the direct call would still work — sudo shadow supplies the password — but skips idempotency + auto-update). Idempotency depends on `dpkg -l` naming matching the requested name.

### 2.3 `add-apt-repository()` (add-apt-repository.sh)

Idempotency: greps `^deb .*<spec>` across `/etc/apt/sources.list.d/*`; skips if present (`ppa:` prefix stripped for the check). If absent: `sudo add-apt-repository <repo> -y` then `apt-get update --force` (shadow recursion — both are the shadowed functions).

### 2.4 `git()` (git.sh)

Two concerns:
- Auth: `cloudify_git_authenticate <url>` (git.sh:10) — backs up `~/.gitconfig` via `pkg_backup`, resolves the domain via `cloudify_parse_git_url`, exports `GIT_TOKEN` = `CLOUDIFY_GITHUB_READONLY_TOKEN` (github, preferred) or `CLOUDIFY_GITHUBPWD` fallback, `CLOUDIFY_GITLABPWD` (gitlab). Writes `~/.git-askpass` echoing `$GIT_TOKEN`, sets `GIT_ASKPASS`, and adds `url.insteadOf` rules forcing HTTPS (`https://api@github.com/`, `https://ssh@gitlab.com/`, etc.). UNSUPPORTED DOMAINS DIE (`die "Git Host $domain is not supported'"`). `cloudify_git_deauthenticate` restores `.gitconfig` via `pkg_restore`.
- Clone-to-pull: `git clone <url> <dir>` into an existing non-empty dir whose origin matches the URL → silently converts to `git pull` (inside a subshell). Different origin → error. Empty/nonexistent dir → real clone with auth.
- Non-clone git ops: pass through to real git when neither `CLOUDIFY_GITLABPWD` nor `CLOUDIFY_GITHUBPWD` is set; otherwise authenticate for the current repo's origin, run, deauthenticate.

Invariants recipes rely on: `pkg_backup`/`pkg_restore` (so `.gitconfig` survives), tokens in `~/.config/cloudify/credentials` forwarded via the payload, recipe never calls `command git` (would bypass askpass and fail on private repos), and any git URL points at github.com or gitlab.com.

---

## 3. Contract a new pkg must satisfy

### 3.1 Files under `pkg/<name>/` (guacamole)

- `init.sh` — REQUIRED. Sourced with `set -Eeuo pipefail`. May `return 0` early (guards). May NOT declare the entrypoints below; the pkg_* API is provided by the environment (no sourcing needed).
- `install.sh` (+ optional `configure.sh`) — split-pkg mode (ADR-008); presence of `install.sh` switches recipe resolution preference. If guacamole is a split pkg: `install.sh` = idempotent bits + install guard; `configure.sh` = re-runnable run phase (rewrite compose/env, restart), no guard. `cloudify install` runs both then verifies; `cloudify configure` runs configure only then verifies. If NOT split, one `init.sh` holds everything.
- `verify.sh` — optional; defines `pkg_verify()` (section 4).
- `.remote-vars` — optional; one UPPERCASE var NAME per line (`#` comments allowed). Declares "name in repo, value from caller env" (ADR-007).
- `@default`, `@<tag>`, `#<os>` — empty tag files. Do NOT add `@default` unless guacamole belongs on every node.
- `README.md` — house style per `pkg/hermes/README.md`, `pkg/k3s-server/README.md` (config table, exposure, gotchas, verify semantics).

### 3.2 How the router invokes a pkg — pkg_* entrypoints

There are NO `pkg_install` / `pkg_verify` entrypoints to author. The router drives packages entirely by FILE discovery + the public API functions in `lib/package-api.sh`:

- `pkg_depends <pkg...>` (call inside a recipe) → sources the dep's recipe (`_cloudify_source_pkg_phases`) and runs `_cloudify_run_verify` after it. Fallback to `pkg_apt_install` if no cloudify recipe exists.
- `pkg_apt_install`, `pkg_apt_update [--force]`, `pkg_apt_repository` — thin wrappers over shadows.
- `pkg_install_release <name> <repo>` — GitHub latest-release installer (own auth: real `sudo -kS ... <<<"$password"`).
- `pkg_backup` / `pkg_restore` — rotated backup machinery (used by git shadow).
- `pkg_in_startuprc <line>` — deduped ~/.bashrc writer.
- `PKG_DEBUG`, `log_info`, `log_warn`, `log_error`, `die`, `msg` — recipe output helpers.

`cloudify_install_package` and `cloudify_configure_package` (packages.sh) are the public dispatchers over `pkg_depends`.

### 3.3 Where recipe runtime vars come from

Inside a recipe body, config is read as plain env: `GUACAMOLE_ADMIN_USER="${GUACAMOLE_ADMIN_USER:-guacadmin}"`. Values were placed in the env by:

- LOCAL install (`cloudify install guacamole`, no `--on`): the caller's env only. [AMBIGUOUS — see 3.6] On this code path `~/.config/cloudify/pkgs/guacamole.yaml` is NOT auto-loaded into recipe env; nothing exports it for a local install.
- REMOTE install (`--on`): the payload exports (section 1.2), built from `.remote-vars` env values, per-pkg yaml, remote-vars.yaml, deployment vars. Precedence (remote.sh): remote-vars.yaml > rightmost CLI pkg > leftmost > deps > deployment-wide; env values from `.remote-vars` override disk values of the same name; first-write-wins on the claim ledger.
- Verify hook (both paths): `_cloudify_run_verify` loads `pkgs/<pkg>.yaml` locally (see 4).

### 3.4 `.remote-vars` format and secret-name → value mapping

Real examples: `pkg/k3s-server/.remote-vars` = `K3S_TOKEN`; `pkg/k3s-agent/.remote-vars` = `K3S_TOKEN\nK3S_URL`. The file lists NAMES only. Value resolution is `_try_claim_env`:

```
name in .remote-vars  +  caller env has it  → forwarded (env value wins over disk yaml claims)
name in .remote-vars  +  caller env unset   → warn + NOT claimed from env (but a same-named value from
                                              remote-vars.yaml or pkgs/<pkg>.yaml may still claim it next)
```

For guacamole, a `.remote-vars` listing `GUACAMOLE_ADMIN_PASSWORD` means callers run `GUACAMOLE_ADMIN_PASSWORD=... cloudify --on <host> install guacamole` (also expressible as a deployment var, ADR-011). If guacamole prefers disk config, skip `.remote-vars` and use `~/.config/cloudify/pkgs/guacamole.yaml` (flat `KEY: value`, quotes optional, single source of truth for name+value). Both patterns coexist for different vars in the same pkg (k3s-server uses .remote-vars for K3S_TOKEN and plain env for K3S_VERSION).

### 3.5 Per-pkg yaml

`~/.config/cloudify/pkgs/<pkg>.yaml` — flat `KEY: value` lines, regex-gated to `^[A-Z_][A-Z0-9_]*:`, values trimmed + quote-stripped by `_cloudify_load_yaml_vars` / `_try_claim`. Missing file silently ignored. Yaml claims export into the caller env AND into the payload. On this host the directory is chmod 700 and contains 4 files (see preamble). A `guacamole.yaml` here is the natural home for `PKG_VERIFY_TIMEOUT` and non-secret defaults; secrets should prefer `.remote-vars`/env or deployment vars.

### 3.6 First-write-wins claiming, env precedence — and the localhost asymmetry

First-write-wins operates on the NAME ledger (temp file) — first claimer keeps the name and its exported value; later claimers skip. Caller env via `.remote-vars` is the one exception that overrides an earlier disk value (it re-exports unconditionally) but never steals an unclaimed slot twice.

[AMBIGUOUS — worth confirming before authoring] A LOCAL (no `--on`) `cloudify install` appears NOT to load per-pkg yaml into the recipe env: `_cloudify_load_yaml_vars` is called only in (a) `_cloudify_pkg_remote_vars` (remote.sh) and (b) `_cloudify_run_verify` (package-api.sh:345, localhost verify path). Grep of `lib/` + router confirms no other caller. README states yaml vars "are forwarded to the remote host when installing via --on" — consistent. Practical consequence: recipes must not require yaml-only vars for local installs; integration tests always use `--on`, so they exercise the forwarding path, not this gap.

### 3.7 Install guards — `CLOUDIFY_FORCE` / `CLOUDIFY_CLEAR_DATA`

Framework semantics (packages.sh + package-api.sh):
- `CLOUDIFY_FORCE` = set (`true`) for EXPLICIT dispatch (`cloudify install guacamole`, or remote via `_cloudify_dispatch` export); UNSET for deps pulled by `pkg_depends` (dependency subshell `unset CLOUDIFY_FORCE; unset CLOUDIFY_CLEAR_DATA`). `--clear-data` implies FORCE.
- `CLOUDIFY_CLEAR_DATA` = set by `--clear-data`; implies FORCE.

Prescribed guard pattern (README + `pkg/docker/init.sh`, `pkg/open-webui/init.sh`, `pkg/k3s-server/install.sh`):

```bash
if <already_installed_check> && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "<Pkg> already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    log_info "Clearing <pkg> data..."
    rm -rf <data_dir>
fi
```

Software (binaries, images, compose files) is overwritten on FORCE; DATA (db volume, uploads) is preserved unless `--clear-data`. For guacamole: `<already_installed_check>` could be `-f /opt/guacamole/docker-compose.yml && docker compose ls`, data dir = the postgres volume (`docker volume` or a bind dir); compose + env files are regenerated on every (forced) install, NOT data. Guard must come AFTER `pkg_depends` and BEFORE destructive work (README recipe conventions).

---

## 4. verify.sh contract (grounded in `_cloudify_run_verify`, package-api.sh:336-365)

Discovery: `cloudify_package_verify_path <pkg>` — resolves the recipe path, then tests sibling `verify.sh` (package-api.sh:319-329). No verify.sh → `_cloudify_run_verify` returns 0 immediately.

Execution, per retry attempt:

```bash
timeout="${PKG_VERIFY_TIMEOUT:-30}"
while (( elapsed < timeout )); do
    attempt=$((attempt + 1))
    if last_err=$( { source "$verify_path" && pkg_verify; } 2>&1 ); then
        log_info "Verified ${pkg} (attempt ${attempt}, ${elapsed}s elapsed)."
        return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done
log_error "Verification FAILED for ${pkg} (timeout after ${timeout}s)."
return 1
```

- **Clean subshell**: the whole thing runs in a `$( )` command-substitution subshell. The recipe's local (non-exported) shell variables are GONE. What verify.sh sees: exported env vars (yaml-loaded vars are `export`ed; recipe vars only if the recipe `export`ed them — recipes don't) + on-disk state (files, running services). `if` suspends errexit for the tested command.
- **File contract**: `verify.sh` defines exactly one function `pkg_verify` that returns 0 = healthy, non-zero = not yet healthy (retried). It is sourced fresh EVERY attempt → must be idempotent. Same file serves install+verify and verify-only paths (`cloudify --verify install`, `cloudify verify <pkg>` — router dispatches `_cloudify_run_verify` for each).
- **Inputs**: env vars from `pkgs/<pkg>.yaml` (loaded by `_cloudify_run_verify` itself on localhost, line 345: `_cloudify_load_yaml_vars "$config_dir/pkgs/${pkg}.yaml"`; on remote they arrive via the install payload) — or config files the recipe wrote. Never recipe-local vars, never hardcoded host:port (hermes-openwebui verify.sh comment block; mode detected by WHICH env var is populated, not hostnames).
- **PKG_VERIFY_TIMEOUT**: `pkgs/<pkg>.yaml` or env; forwarded automatically for remote installs — `PKG_VERIFY_TIMEOUT` is a FIXED member of the template (remote.sh:55) and of the envsubst allow-list (remote.sh:287), independent of any pkg claims. Default 30s, 2s sleeps. A guacamole first install (postgres init + image pulls) should raise it (e.g. 180-300s) — the health check must tolerate the compose stack's slow first boot.
- **Exit-code semantics**: `_cloudify_run_verify` returns 1 after timeout; the retry loop exits 0 on first success. Callers (`pkg_depends`, `cloudify_configure_package`) treat verify failure as a package failure (recorded in `failed_packages`), but `pkg_depends` continues to the next package and returns 1 at the end. `CLOUDIFY_NO_VERIFY=true` skips verify entirely (`--no-verify`).
- **Deep verify**: verification runs after EVERY package including deps inside `pkg_depends`. Contract for rewiring deps: (a) a parent overriding a dep via env → declare in parent's yaml (forwarded parent-priority); never set it imperatively in the parent recipe body (runs after the dep was already verified). (b) a parent hardcoding a rewire of a dep → parent's verify.sh asserts it, dep's verify.sh must NOT.

---

## 5. Adding pkg/guacamole touches ONLY these paths

New files, nothing else:

- `pkg/guacamole/init.sh` (or `install.sh` + `configure.sh` split) — recipe
- `pkg/guacamole/verify.sh` — verification hook
- `pkg/guacamole/.remote-vars` — secret NAMES (if env-provided)
- `pkg/guacamole/README.md` — user docs
- (caller-side, NOT in repo) `~/.config/cloudify/pkgs/guacamole.yaml` — disk config
- `tests/integration/package-guacamole.bats` + unit test (TDD cycle per AGENTS.md)

MUST NEVER change: `cloudify` router, `lib/` (incl. `lib/shadows/*.sh`, `remote.sh`, `package-api.sh`, `pkg-config.sh`, `credentials.sh`, `packages.sh`, `deployments.sh`), the bootstrap gist, any existing `pkg/*` recipe behavior, `tests/` helpers.

Why adding only `pkg/guacamole/` files cannot break the mechanisms:

1. Package discovery is data-driven over `$CLOUDIFY_DIR/pkg/` (a find over directories; package presence = directory exists, packages.sh:41). A new directory adds a package; it changes no dispatch logic. `cloudify packages` lists it; `pkg_depends guacamole` or `cloudify install guacamole` resolve it exactly like the other 90 dirs.
2. Var forwarding is driven by files INSIDE the new pkg dir (`.remote-vars`) plus caller-side config; `_cloudify_pkg_remote_vars` walks whatever recipes exist. No mechanism code path changes; guacamole merely claims names like k3s-server already does.
3. Shadows activate by name at router startup, not per-package; a new recipe is a new consumer of the same invariants (section 2) and cannot alter the loader (`lib/shadow.sh` glob-sources `lib/shadows/*.sh` — new shadow files WOULD be picked up, which is exactly why none may be added).
4. Verify is opt-in by file presence: no `verify.sh` → no-op (`cloudify_package_verify_path` returns 1). Adding one only affects guacamole's own installs; the retry/source machinery already exists and is shared.
5. Recipe resolution specificity (os/distro/version suffixed filenames, packages.sh) means guacamole files never collide with another package's namespace (`pkg/<name>/` prefix isolates everything).

---

## 6. Landmines — concrete ways the guacamole recipe could break the machinery

**L1 — Secrets with `'` or newlines break the payload.** envsubst splices the raw value into `export X='<value>'` (no escaping anywhere in remote.sh). Verified: value `it's` yields `export GUACAMOLE_ADMIN_PASSWORD='it's'` — remote shell mis-parse or injection; a newline injects a whole new line into the payload.
Avoid: values containing `'` or control chars (validate at the source, or generate the secret ON the host — e.g. the recipe computes the salt/hash remote-side instead of receiving a pre-baked string).
Safe: `[A-Za-z0-9_-]`/URL-safe values only in env/yaml secrets.

**L2 — Piping big data through shadowed `sudo` into a stdin-reading command.** `echo x | sudo tee f` is fine; but `cat initdb.sql | sudo docker exec -i <db> psql ...` with a >10000-char dump hits the sudo shadow temp-file branch (`command sudo ... "$lineargs" "$tfile"`): the file is appended as a TRAILING ARGUMENT → `docker exec -i <db> psql -U guac <tfile>` treats it as a positional psql arg — wrong. Below 10000 chars the data is replayed as `echo '<data>' | ...` inside `bash -c` — breaks on `'` in the SQL, and quotes/newlines in SQL dumps are guaranteed.
Avoid: any `| ... sudo <cmd-that-reads-stdin>`.
Safe: run docker WITHOUT sudo (user is in the docker group; `pkg/docker/init.sh` adds it — the recipe just must not assume the current ssh session already has the group: `newgrp` caveat is real, but on remote installs the ssh user usually has it after docker install only for NEW sessions). Safest documented pattern: write SQL to a host file and `docker exec -i <db> psql ... < /path/file.sql` (shell redirection, no sudo, no shadow, any size) or `docker cp` the file in. `docker compose exec -T` also avoids sudo entirely.

**L3 — A shadowed-command misuse that silently drops the shadow guarantee.**
- `sudo apt-get install ...` inside a recipe bypasses apt idempotency/auto-update (still works via sudo shadow but loses the layers).
- `command git clone ...` bypasses askpass auth (fails on private repos / insteadOf rewrites).
- `git clone <url-not-github/gitlab>` dies (`die "Git Host ... not supported"`).
- `sudo find ...` emits the stray `echo dealing with find` on stdout (sudo.sh find branch) — never parse stdout of a sudo find.
Avoid: bare `sudo`/`command git`/`command apt-get` in recipes. Safe: use the plain command names + the `pkg_*` wrappers (their whole point).

**L4 — stdin is /dev/null inside recipes.** The payload ends with `exec > >(tee ...) 2>&1 </dev/null`. Any recipe logic that expects interactive stdin breaks. In particular the sudo shadow's stdin detection relies on this being consistent: TTY/no-pipe cases are handled, but a recipe that does `read` or `cat` expecting data will hang/fail.
Avoid: interactive reads in recipes. Safe: read config from env/yaml/files only; pass stdin explicitly per command (heredocs, `< file`).

**L5 — Declaring a var in `.remote-vars` but not guaranteeing a value.** Unset names warn and are NOT forwarded by the env path. Recipe must then either have a sane default (`${VAR:-default}`), read a config file, or the same name must exist in per-pkg yaml / remote-vars.yaml / deployment vars (env → yaml → deployment fallback chain). Also remember: `.remote-vars` values can only come from the caller env — CI/fixtures must export them.

**L6 — Verify depending on recipe-local unexported vars.** `_cloudify_run_verify` sources `verify.sh` in a `$( )` subshell: only exported env + disk state survive. Writing `GUACAMOLE_PORT="$PORT"` unexported in the recipe and reading `$GUACAMOLE_PORT` in verify.sh silently fails (empty).
Avoid: verify referencing recipe locals or requiring env values the caller didn't forward.
Safe (per README hard rules + hermes-openwebui verify.sh): defaulted env reads (`: ${CLOUDIFY_GUACAMOLE_PORT:-8080}`), or read the value back from a file the recipe wrote (`/opt/guacamole/.env`, `docker-compose.yml`); no hardcoded endpoints; idempotent; standard commands only (a verify.sh may define local helpers inside the file, but may not call recipe-defined functions).

**L7 — Remote verify-only (`--verify --on <host> install <pkg>`) forwards NO per-pkg vars.** The router sends `cloudify_remote <host> "verify <pkg>"`; `_cloudify_pkg_remote_vars` only walks pkgs when the argv contains `install`/`--install`/`configure`/`--configure` — "verify" matches none. Per-pkg yaml + `.remote-vars` values are absent in that mode; only remote-vars.yaml + fixed template vars (incl. PKG_VERIFY_TIMEOUT) reach the host. Local `cloudify verify` DOES load pkgs/<pkg>.yaml. So guacamole verify.sh must work with only defaults + on-disk state on the remote verify-only path, or document that `--verify` remote needs vars in remote-vars.yaml.
[Consequence of code read; the two existing verify.sh files happen to tolerate it via defaults — no test explicitly asserts remote verify-only forwarding.]

**L8 — Split-pkg phase ordering vs secrets.** In a split pkg both install.sh and configure.sh are sourced in ONE subshell (`_cloudify_source_pkg_phases`), so install-phase exported vars ARE visible to configure. But install guards returning early in install.sh don't stop configure.sh. If the DB init / admin hash must run exactly once, guard it on disk state (init marker file, volume existence), not on the install/configure split. And any var the CONFIGURE phase needs must be forwarded too (configure dispatch DOES trigger the var walk — `configure` is in the detect list — but only for the packages named on the configure command line).

**L9 — Guard correctness.** Placing the install guard before `pkg_depends` (guacamole needs docker always), or a guard whose `already_installed` check is true while data is missing, skips repair silently. And on `CLOUDIFY_FORCE` (explicit reinstall) with `--clear-data`, data dirs must be wiped BEFORE software is rewritten, or stale postgres data with a changed admin password/salt persists (guacamole's RDP records + users live in postgres — the clear-data path must drop the volume, not just rewrite compose).

**L10 — Shadowed `add-apt-repository` / apt naming assumptions** (only if guacamole adds apt sources): repo idempotency greps sources.list.d for the spec string; DEB822-format repos added via a raw `tee` (like `pkg/docker/init.sh` does) are invisible to the grep → re-adding is not detected. Use the shadow or accept the double-add. Not expected for guacamole (docker-compose stack only).

**L11 — Value masking in debug output is best-effort.** `$DEBUG && msg "$cloudify_remote_payload_secure"` masks `PWD=`/`PASSWORD*=`/`SECRET*=`/`TOKEN*=`/`KEY*=` patterns via crude globs. A secret var named e.g. `GUACAMOLE_ADMIN_PASSWORD` matches `PASSWORD*='*'`… only when the export line is exactly `export NAME='value'` on one line with no spaces. Name secrets with PASSWORD/TOKEN/KEY in the NAME so the crude mask catches them, and never enable DEBUG on hosts where the payload is sensitive.
