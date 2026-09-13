# Cloudify remote env-var forwarding + shadow commands: end-to-end description

Read-only description of the code as it exists today. Purpose: the mandatory
precondition artifact for the project CRITICAL GATE before any `lib/` change.
File:line citations are against the current checkout.

**Status and authority.** This is a *descriptive* artifact. It records what the
code does today, including behaviour the redesign deliberately changes. Where it
conflicts with `REDESIGN.md`, ADR-022 or ADR-023, those documents win. A later
phase's CRITICAL GATE step may **supersede** an invariant below, not only append
to it; when it does, the superseding step must restate the invariant it replaces
and say why. Two invariants are already superseded by design: #8 (the context is
no longer metadata-only; see `REDESIGN.md:302`) and re-assert item 4 (the
envsubst allow-list gains names, e.g. the Phase 4 frame nonce).

---

## 1. The payload path

### 1.1 The template is a bash function whose body is *literal text*

The remote payload is defined as a function, `cloudify_remote_payload_template`,
in `lib/remote.sh:24-77`. Every value that must travel from the local machine is
written as a single-quoted placeholder, e.g.:

- `lib/remote.sh:34` `export CLOUDIFY_DISABLE_COLORS='$CLOUDIFY_DISABLE_COLORS'`
- `lib/remote.sh:37` `export CLOUDIFY_HOSTPWD='$CLOUDIFY_REMOTE_PWD'`
- `lib/remote.sh:58` `: _CLOUDIFY_PKG_EXPORTS_` (placeholder for package vars)

Because the `$VAR` references are single-quoted *inside the function body*, bash
does not expand them when the function is parsed; the function body stores the
literal text `$CLOUDIFY_DISABLE_COLORS`, `$CLOUDIFY_REMOTE_PWD`, etc. This is the
whole point of the single-quote convention: `declare -f` can later dump that
literal text.

### 1.2 Extraction with `declare -f`

`lib/remote.sh:234`:

```bash
cloudify_remote_payload=$(declare -f cloudify_remote_payload_template | tail -n +3 | head -n -1)
```

`declare -f <func>` prints the function definition:

```
cloudify_remote_payload_template ()
{
    export CLOUDIFY_IS_LOCAL=false
    ...
}
```

`tail -n +3` drops the first two lines (the `cloudify_remote_payload_template ()`
header and the opening `{`). `head -n -1` drops the closing `}`. The result is
the body text with all single-quoted `$VAR` placeholders and the
`_CLOUDIFY_PKG_EXPORTS_` marker still literal.

### 1.3 Package exports injected at the placeholder

`lib/remote.sh:221-229` builds, for every claimed package var name, two strings:

```bash
pkg_envsubst="$pkg_envsubst \$$var"
pkg_exports="${pkg_exports}"$'\n'"    export $var='\$$var'"
```

- `pkg_envsubst` appends ` $VAR` (a double-quoted expansion -> ` $NAME`) to the
  envsubst allow-list, so the name WILL be substituted locally.
- `pkg_exports` appends a literal line `    export NAME='$NAME'`. The `'\$$var'`
  is single-quoted shell text producing a literal `$NAME` inside single quotes
  (the `\$` yields a literal `$`, `$var` expands to the name).

`lib/remote.sh:237` then splices the exports in:

```bash
cloudify_remote_payload="${cloudify_remote_payload//_CLOUDIFY_PKG_EXPORTS_/$pkg_exports}"
```

Result, for a package declaring `MY_SECRET`:

```
    export MY_SECRET='$MY_SECRET'
```

### 1.4 envsubst with an explicit allow-list

`lib/remote.sh:241-242`:

```bash
cloudify_remote_payload=$(envsubst \
    "\$CLOUDIFY_DISABLE_COLORS \$DEBUG \$CLOUDIFY_LOG_LEVEL \$CLOUDIFY_NO_DEFAULTS \$CLOUDIFY_CLEAR_DATA \$CLOUDIFY_FORCE \$CLOUDIFY_NO_VERIFY \$PKG_VERIFY_TIMEOUT \$CLOUDIFY_FORCE_UPDATE \$CLOUDIFY_UPDATE_DELAY \$CLOUDIFY_REMOTE_USER \$CLOUDIFY_REMOTE_PWD \$CLOUDIFY_GITHUBUSER \$CLOUDIFY_GITHUBPWD \$CLOUDIFY_GITHUB_READONLY_TOKEN \$CLOUDIFY_GITLABUSER \$CLOUDIFY_GITLABPWD \$CLOUDIFY_RCLONE_REMOTE \$CLOUDIFY_RCLONE_REMOTE_REGION \$CLOUDIFY_RCLONE_REMOTE_ENDPOINT \$CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID \$CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY \$RESTIC_PASSWORD \$CLOUDIFY_BOOTSTRAP_URL \$CLOUDIFY_LOG_BASENAME${pkg_envsubst}" \
    <<< "$cloudify_remote_payload")
```

`envsubst` with an explicit allow-list substitutes ONLY the listed names. It is a
pure text substitution: it does not parse shell quoting. So a single-quoted
`'$CLOUDIFY_REMOTE_PWD'` is replaced with the local value, and the single quotes
in the text survive around the substituted value. That is why the value must be
single-quoted in the template: after substitution the remote shell sees
`export CLOUDIFY_HOSTPWD='s3cret!pa$$word'` and does not re-expand `$pa` / glob
the value.

The local values themselves were resolved and exported into the calling shell
*before* this line by `_cloudify_dispatch_vars` -> `cloudify_context_build`
(`lib/remote.sh:210-211`, `lib/context.sh:181`). `envsubst` reads them from the
process environment.

### 1.5 Append the command and send on stdin

`lib/remote.sh:246`:

```bash
cloudify_remote_payload="$cloudify_remote_payload; cloudify $* </dev/null"
```

`lib/remote.sh:270-274` writes the payload to a 0600 temp file and pipes it to
the remote as the stdin of `bash -s` (never on argv, so no secret appears in the
process list):

```bash
payload_file=$(mktemp "$CLOUDIFY_TMP/cloudify-payload-XXXXXX")
chmod 600 "$payload_file"
printf '%s\n' "$cloudify_remote_payload" > "$payload_file"
ssh ... "$CLOUDIFY_REMOTE_USER@$host" 'bash -s' < "$payload_file"
```

Concrete example of the whole path for a package that declares `MY_SECRET`
(value `tok123$with$dollars`, provided by caller env):

```
template body:  export MY_SECRET='$MY_SECRET'          (injected at lib/remote.sh:228)
after envsubst: export MY_SECRET='tok123$with$dollars' (lib/remote.sh:241)
remote bash:    export MY_SECRET='tok123$with$dollars' (single quotes protect $with/$dollars)
```

---

## 2. Names intentionally left for the remote side

The envsubst allow-list is the *complete* decision of what is substituted
locally. Any `$NAME` or `$(...)` not in the list survives as literal text and is
evaluated by the remote shell when `bash -s` runs the payload.

Concrete examples:

- **`$HOME` — resolved remotely.** `lib/remote.sh:41`
  `export CLOUDIFY_LOCAL_BIN="$HOME/.local/bin"` is double-quoted and `$HOME` is
  NOT in the allow-list, so it survives envsubst and expands to the *remote*
  user's home. Same at `lib/remote.sh:55` inside `find $HOME/cloudify/...`.
- **`$(...)` command substitutions — resolved remotely.** `lib/remote.sh:55`
  `$(find $HOME/cloudify/.#last_update ...)`, `lib/remote.sh:57`
  `$(curl -sL '$CLOUDIFY_BOOTSTRAP_URL')`, and `lib/remote.sh:68`
  `$(date +%Y%m%d-%H%M%S)`. envsubst only rewrites `$VAR` names, never `$(...)`,
  so these run on the remote host. Note the URL *inside* the curl substitution is
  still single-quoted and allow-listed, so it is substituted locally first.
- **The single-quoted allow-listed names are NOT remote-side.** Every single-quoted
  `$VAR` in the template is in the allow-list, so the "single-quoted" form is the
  *local* substitution carrier; the remote-side names are the non-allow-listed
  ones (`$HOME`, `$(...)`).

Net: local substitution = allow-listed names (single-quoted to protect the
value). Remote resolution = anything not allow-listed (`$HOME`, command
substitutions, and the fixed literals like `DEBIAN_FRONTEND=noninteractive`).

---

## 3. First-write-wins var claiming

### 3.1 What claims a name

`lib/vars.sh:56-66` `_cloudify_vars_claim`:

```bash
_cloudify_vars_claim() {
    local name="$1"
    [[ -n "${_CLOUDIFY_VARS_LEDGER:-}" ]] || return 0
    if grep -qx "$name" "$_CLOUDIFY_VARS_LEDGER" 2>/dev/null; then
        return 1
    fi
    echo "$name" >> "$_CLOUDIFY_VARS_LEDGER"
    return 0
}
```

When `_CLOUDIFY_VARS_LEDGER` is set, the first caller to claim a name writes it
to the ledger (one name per line) and wins; every later claim returns 1 and is
skipped. `cloudify_context_build` sets `_CLOUDIFY_VARS_LEDGER` before walking
(`lib/context.sh:208-210`) and every reader is therefore non-clobbering.

The single export decision is `lib/vars.sh:163-196` `_cloudify_vars_emit`, which
calls `_cloudify_vars_claim "$name" || return 0` at `lib/vars.sh:172` *before*
any emptiness check or value resolution. So claiming happens on presence of the
key, not on the value being non-empty.

### 3.2 Order (weakest -> strongest)

`lib/context.sh:259-291` walks, in order:

1. `cloudify_vars_deployment_read "$deployment"` (`lib/context.sh:262`)
2. application defaults `_cloudify_load_yaml_vars ... application` (`lib/context.sh:264-267`)
3. mapped application inputs (`lib/context.sh:269-285`)
4. packages, rightmost-first with dependencies (`lib/context.sh:288-291`,
   `_cloudify_context_walk_pkgs` at `lib/context.sh:239-257`)
5. `cloudify_vars_global_read` (`lib/context.sh:292`)
6. `cloudify_vars_env_read "${candidates[@]}"` (`lib/context.sh:293-295`)

This order (env read last) plus the no-clobber env check inside
`_cloudify_vars_emit` (`lib/vars.sh:176-179`) reproduces the ladder:

`recipe < global < package < application < deployment < caller env`

The env source is strongest because, for any file-store emit, if the name is
already set in the caller env (`${!name:-}` non-empty) the emit records
`environment` and returns without overwriting (`lib/vars.sh:176-179`); the
caller-env value was already present in the shell.

### 3.3 Two sources, same name

Because the ledger is first-write-wins and the walk is ordered weakest-first,
the *first source visited* that holds the name wins. Example: `KEY` present in
both the global store and the package store -> package read runs before global
read, package claims, global read's claim returns 1 and is skipped. `KEY`
present in caller env and in the deployment store -> deployment read visits
first and claims, but the no-clobber env check sees `KEY` already set, records
`environment`, and does not overwrite; the env read at the end finds the name
already claimed.

### 3.4 Present-but-empty store value now wins

The claim at `lib/vars.sh:172` runs before any emptiness test, and the flat
reader does not drop `KEY:` lines with an empty value. `lib/vars.sh:200-224`
`_cloudify_load_yaml_vars` only skips fully-empty/comment lines
(`lib/vars.sh:208-209`) and then calls `_cloudify_vars_emit "$key" "$value" ...`
(`lib/vars.sh:222`) even when `value` is empty. So a store line `KEY:` (key
present, value empty) claims the name and exports an empty value
(`lib/vars.sh:186-188`), preventing any weaker source from supplying it. This is
the "present but empty wins" behavior: the name is claimed on key presence, not
on value non-emptiness.

---

## 4. The dispatch context (`lib/context.sh`)

### 4.1 Where it is built

The parent creates the file *before* the child starts, so the parent already
knows the path for the later registry write; the child fills it.

- `lib/remote.sh:94-99` `_cloudify_context_file_init`:

```bash
CLOUDIFY_CONTEXT_FILE=$(mktemp "$CLOUDIFY_TMP/cloudify-context-XXXXXX") ...
chmod 600 "$CLOUDIFY_CONTEXT_FILE"
export CLOUDIFY_CONTEXT_FILE
```

- The router's local-install path calls it at `cloudify:245-247`
  (`_cloudify_execute_package_action`, for non-verify actions).
- The remote path calls it at `lib/remote.sh:141` (`cloudify_remote`, which
  backgrounds `cloudify_remote_sync`).
- `cloudify_remote_sync` (a direct `cloudify exec`/test call with no parent)
  makes its own and self-removes it via a RETURN trap (`lib/remote.sh:203-208`,
  `lib/remote.sh:212-215`).

`cloudify_context_build` (`lib/context.sh:181`) does the resolution and writes
the context file via an atomic 0600 temp + `mv` (`lib/context.sh:202-203`,
`lib/context.sh:348-349`).

### 4.2 What the 0600 context file contains

Metadata only — never a plaintext value, never a resolved value, never payload
text. Schema (from `lib/context.sh:37-51` and the write block
`lib/context.sh:322-346`):

- `context_version: 1`
- `action`, `deployment`, `phase`, `target` (a `node<TAB>instance<TAB>ssh_host`
  triple from `CLOUDIFY_CONTEXT_TARGET` or `_CLOUDIFY_CUR_TARGET`,
  `lib/context.sh:302-303`), `top_kind`
- per resolved name:
  - `value.<NAME>.source` (environment|deployment|package|global|recipe)
  - `value.<NAME>.form` (literal|reference)
  - `value.<NAME>.secret` (true|false)
  - `value.<NAME>.reference` (the `@<backend>:<locator>` text when form=reference)
  - `value.<NAME>.digest` (sha256 hex of a literal secret, computed at
    `lib/context.sh:337-340`)

The provenance (`source` label + reference text) is captured at the single export
decision inside `_cloudify_vars_emit` via `_cloudify_vars_sources_record`
(`lib/vars.sh:73-77`, called at `lib/vars.sh:179` and `lib/vars.sh:195`), written
to a 0600 temp file `_CLOUDIFY_VARS_SOURCES` (`lib/context.sh:200-201`), then read
back first-claim-wins into `_ctx_source`/`_ctx_ref` (`lib/context.sh:306-318`).
No store is read a second time during context build.

### 4.3 Where it is removed

- On a successful backgrounded dispatch: `lib/registry.sh:415-417`
  `_cloudify_registry_record_bg` removes it after writing the registry record.
- On a failed dispatch: the router removes it itself in the wait loop,
  `cloudify:822-824`.
- On a self-created context (no parent): the RETURN trap in
  `cloudify_remote_sync` removes it (`lib/remote.sh:212-215`).

---

## 5. Registry record and run snapshot

### 5.1 Registry observation record

Written after a *successful* dispatch by the router's wait loop,
`cloudify:807-824`: for each finished background pid, `wait` -> rc 0 ->
`_cloudify_registry_record_bg "$_bg_pid"` (`cloudify:815`).

`_cloudify_registry_record_bg` (`lib/registry.sh:388-419`) reads the router's
pid-keyed metadata arrays `_CLOUDIFY_BG_ACTION`, `_CLOUDIFY_BG_PKGS`,
`_CLOUDIFY_BG_TARGET`, `_CLOUDIFY_BG_CONTEXT` (declared in `main()`,
`cloudify:409-412`; filled by `_cloudify_note_bg`, `cloudify:183-193`). It skips
verify dispatches and unset `CLOUDIFY_DEPLOYMENT` (`lib/registry.sh:391-397`),
and refuses to write if the context file is missing/unreadable
(`lib/registry.sh:399-402`) — "never a second walk".

The record is built by `cloudify_registry_record_build`
(`lib/registry.sh:298-368`), which reads each declared name's raw value through
`_cloudify_registry_context_raw` (`lib/registry.sh:260-278`), then written
atomically by `cloudify_registry_record_apply` -> `cloudify_registry_put`
(`lib/registry.sh:373-378`, `lib/registry.sh:100-116`) at:

```
<node-dir | fallback>/[<instance>/]deployments/<id>/pkgs/<pkg>/config.yaml
```

(see `lib/registry.sh:1-20` and `cloudify_registry_file` `lib/registry.sh:86-99`).
Uninstall marks `removed_at`; the registry is observation, never a precedence
source (`lib/registry.sh:1-8`).

### 5.2 Run snapshot

Written by the runbook engine at `lib/runbooks.sh:1506-1524` (step 6 of
`cloudify_runbook_execute`), *always* (success or failure), to:

```
$CLOUDIFY_DEPLOYMENTS_DIR/$deployment/runs/<UTC>.yaml
```

via `_cloudify_runbook_snapshot` (`lib/runbooks.sh:441-457`), atomic 0600 temp +
`mv`. It records `status`, `started_at`, `finished_at`, `runbook`, the
`target.<name>` lines, the `value.<NAME>` lines, and `output.<name>` lines.

The `value.<NAME>` lines are seeded in step 3 (`lib/runbooks.sh:1347-1412`):
either replayed verbatim from the source snapshot
(`CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES`, `lib/runbooks.sh:1358-1367`) or, on a fresh
run, from the deployment store plus the resolver view built once from the step
packages (`lib/runbooks.sh:1368-1412`, using `_cloudify_runbook_source_label`
`lib/runbooks.sh:143-155` and `_cloudify_runbook_resolver_value`
`lib/runbooks.sh:185-207`). Replay seeds its environment from a snapshot before
executing (`lib/runbooks.sh:1614-1688`).

---

## 6. Shadow commands (`lib/shadow.sh`, `lib/shadows/*`)

Loader: `lib/shadow.sh:6-13` sources every `lib/shadows/*.sh` in glob order. The
router sources `lib/shadow.sh` so the shadow *functions* override the real
binaries for all recipe code in that shell and on the remote (the payload runs
`cloudify init`, which re-sources them).

### 6.1 `sudo` (`lib/shadows/sudo.sh`) — password injection

`function sudo()` at `lib/shadows/sudo.sh:15`. Depends on:

- `cloudify_get_password` (`lib/utils.sh:292-302`) which reads `CLOUDIFY_HOSTPWD`
  (`lib/utils.sh:300`). On the remote, the payload exported
  `CLOUDIFY_HOSTPWD='$CLOUDIFY_REMOTE_PWD'` (`lib/remote.sh:37`); locally the
  router maps `CLOUDIFY_HOSTPWD` from `CLOUDIFY_LOCAL_PWD` (`cloudify:398`).
  Empty password -> `die` (`lib/shadows/sudo.sh:18-19`).

Mechanism: it reassembles the command (with special handling for
`add-apt-repository` single-quoting, `sed` expression quoting, and `find` `;`
escaping, `lib/shadows/sudo.sh:22-61`), captures piped stdin into `pipeargs`
(`lib/shadows/sudo.sh:64-74`), then runs

```bash
command sudo -kS -p "" bash -c "$sudocmd" <<<"$password"
```

(`lib/shadows/sudo.sh:84`), feeding the password on stdin via a here-string so
the command's own stdin stays free. For commands over ~10000 chars it falls back
to a temp file (`lib/shadows/sudo.sh:87-92`). `command` bypasses the shadow to
reach the real `sudo`.

### 6.2 `apt-get` / `apt` (`lib/shadows/apt-get.sh`) — idempotency, auto-update, -y

`function apt-get()` at `lib/shadows/apt-get.sh:29`; `function apt()` delegates
at `lib/shadows/apt-get.sh:79`.

- `install`: pre-pass refreshes cache only when something is genuinely missing
  (`lib/shadows/apt-get.sh:33-45`), then installs each package only if
  `_cloudify_pkg_installed` (dpkg `^ii` check, `lib/shadows/apt-get.sh:17-20`)
  says it is absent (`lib/shadows/apt-get.sh:46-55`).
- `update`: only if `--force` or the apt cache is stale >60min
  (`_cloudify_apt_cache_stale`, `lib/shadows/apt-get.sh:9-13`).
- `remove`/`purge`/other: pass through (`lib/shadows/apt-get.sh:57-65`).

Depends on: `sudo` (the shadow, for password), `dpkg -l`, and the apt cache
files under `/var/cache/apt`.

### 6.3 `add-apt-repository` (`lib/shadows/add-apt-repository.sh`) — idempotency, -y, auto-update

`function add-apt-repository()` at `lib/shadows/add-apt-repository.sh:15`.
Extracts the non-flag repo spec (`lib/shadows/add-apt-repository.sh:16-21`),
strips a `ppa:` prefix for the check (`lib/shadows/add-apt-repository.sh:23`),
and only adds when `_cloudify_repo_present` (grep of
`/etc/apt/sources.list.d/*`) fails; then `sudo add-apt-repository <spec> -y`
followed by `apt-get update --force` (`lib/shadows/add-apt-repository.sh:24-29`).
Depends on: `sudo` shadow and `apt-get` shadow.

### 6.4 `git` (`lib/shadows/git.sh`) — authentication, clone-vs-pull

`function git()` at `lib/shadows/git.sh:75`. Depends on `CLOUDIFY_GITLABPWD`,
`CLOUDIFY_GITHUBPWD`, `CLOUDIFY_GITHUB_READONLY_TOKEN` (forwarded by the payload,
`lib/remote.sh:44-48`).

- `clone`: if the target dir already exists and is non-empty, it switches to
  `git pull` after checking same-remote (`lib/shadows/git.sh:103-116`); otherwise
  it authenticates and runs the real clone (`lib/shadows/git.sh:117-124`).
- Other subcommands: if no git credentials are configured, pass through; else
  authenticate around the command (`lib/shadows/git.sh:126-144`).

Authentication (`cloudify_git_authenticate`, `lib/shadows/git.sh:7-42`): selects
`GIT_TOKEN` per domain (gitlab -> `CLOUDIFY_GITLABPWD`; github ->
`CLOUDIFY_GITHUB_READONLY_TOKEN` then `CLOUDIFY_GITHUBPWD`), writes
`~/.git-askpass` to echo the token, sets `GIT_ASKPASS`, and adds
`url.<https://api@domain>/.insteadOf` rewrites to force https for ssh/git URLs.
`cloudify_git_deauthenticate` (`lib/shadows/git.sh:45-48`) restores the backed-up
`.gitconfig`.

---

## 7. Invariants a change must not break

Each is stated as "X must remain true", with the code that would break it.

1. **One resolution per dispatch.** The same walk resolves both the forwarded
   value and its provenance label; no later step may re-derive a value by
   reading a store again. Breakage: any edit that makes
   `cloudify_context_build` skip a source, or that reads a store file after
   build (as `_cloudify_registry_context_raw` does, `lib/registry.sh:270-278`).
   Code to preserve: `lib/context.sh:208-210` (ledger),
   `lib/vars.sh:73-77` (provenance at the single export decision).

2. **The context path never enters ssh argv.** The parent creates the context
   file and records its path in `_CLOUDIFY_BG_CONTEXT`; the path travels only as
   a variable, never as a command argument (so it never leaks into `ps`). Code:
   `lib/remote.sh:94-99` (parent init), `cloudify:190` (`_cloudify_note_bg`
   stores the path), `lib/remote.sh:271-274` (payload via stdin file redirect).
   Breakage: passing `CLOUDIFY_CONTEXT_FILE` as an argument to `ssh`/`bash -c`.

3. **`_cloudify_dispatch_vars` must be invoked with a redirect, never `$(...)`.**
   It exports resolved literals into the calling shell; a command substitution
   would run it in a subshell and lose the exports. Code:
   `lib/remote.sh:119-121` (build with `> /dev/null`), `lib/remote.sh:168-171`
   comment. Breakage: wrapping the call in `$(...)`.

4. **First-write-wins claim order must stay weakest -> strongest.** The ledger
   (`lib/vars.sh:56-66`) plus the walk order in `cloudify_context_build`
   (`lib/context.sh:259-295`) must keep `recipe < global < package < application
   < deployment < env`. Breakage: reordering the reader calls, or claiming
   before the ladder (e.g. moving env read earlier), or removing the no-clobber
   env check (`lib/vars.sh:176-179`).

5. **A present-but-empty store value must still claim its name.** The claim
   precedes emptiness handling (`lib/vars.sh:172` before `lib/vars.sh:186`), and
   `_cloudify_load_yaml_vars` does not skip `KEY:` lines. Breakage: adding an
   `[[ -z "$raw" ]] && return 0` before the claim, or skipping empty-value keys
   in the flat reader.

6. **The payload must never carry a plaintext secret on argv or in the log.**
   Values travel inside the single-quoted payload on stdin, and DEBUG renders
   only names/source/secret-flag, never the value (`lib/remote.sh:250-260`).
   Breakage: printing `$cloudify_remote_payload` or resolved values to stdout,
   or moving payload to ssh argv.

7. **The envsubst allow-list is the sole local-substitution gate.** Only listed
   names are substituted locally; everything else (`$HOME`, `$(...)`) resolves
   remotely. Breakage: switching to unconstrained `envsubst` (no allow-list),
   which would substitute `$HOME`/`$PATH`/etc. locally and corrupt the payload.

8. **The context file is 0600, ephemeral, and removed only after the parent has
   recorded the outcome.** It may carry each declared value's resolved runtime
   form, because the target process needs it (`REDESIGN.md:302`, `:208`), and the
   file must never survive the dispatch. What must never hold a plaintext or
   resolved value is a log, a manifest, package state, a run record or an event.
   Code today: `lib/context.sh:322-346` (write block),
   `lib/context.sh:200-203,348-349` (0600). Breakage: chmod loosening, or letting
   the file outlive the dispatch (`lib/registry.sh:415-417` removes it today).

9. **The registry record and the payload share one resolution.** The record's
   `var.<NAME>` raw value must come from the dispatch context; a dispatch with a
   missing/unreadable context writes NO record and warns, never a second walk.
   Code: `lib/registry.sh:399-402`, `lib/registry.sh:298-368`. Breakage: making
   `_cloudify_registry_record_bg` fall back to re-walking stores when the context
   is absent.

10. **The parent owns context-file cleanup.** Success: removed by
    `_cloudify_registry_record_bg` after the write (`lib/registry.sh:415-417`);
    failure: removed by the router (`cloudify:822-824`); self-created: RETURN
    trap (`lib/remote.sh:212-215`). Breakage: any path that removes the context
    before the registry write, or leaks it on failure.

11. **Shadow overrides must always reach the real binary via `command`.** Each
    shadow ends in `command <real>` (`sudo` at `lib/shadows/sudo.sh:84,91`;
    `git` at `lib/shadows/git.sh:122,139`; `apt-get`/`add-apt-repository` call
    the `sudo` shadow which calls `command sudo`). Breakage: recursion (calling
    `sudo`/`git`/`apt-get` bare inside the shadow).

12. **The sudo password is delivered on stdin, not argv.** `sudo -kS ... <<<`
    `$password` with `-p ""` (`lib/shadows/sudo.sh:84,91`). Breakage: embedding
    `$password` in `bash -c "$sudocmd"` (argv leak), or dropping `command`.

13. **Verify dispatches write no registry record, and an unset
    `CLOUDIFY_DEPLOYMENT` writes no record.** Code: `lib/registry.sh:391-397`,
    and the router excludes verify from context init (`cloudify:245-247`).
    Breakage: moving verify into the record path.

14. **`cloudify_context_read` is exact-key, no partial match.** It matches
    `"$field:"*` then strips the prefix (`lib/context.sh:364-375`). A reader
    that matches a substring would misread `value.A` as `value.AB`. Breakage:
    switching to `grep "$field"`.

---

## 8. The known defect this recovery must remove

**Location:** `_cloudify_registry_context_raw`, `lib/registry.sh:260-278`.

The context file records only *metadata* (source label, form, reference text,
digest) — never the raw value. So when `cloudify_registry_record_build` writes
each `var.<NAME>` line (`lib/registry.sh:354-366`), it must recover the raw
value, and `_cloudify_registry_context_raw` does that by **re-opening the value
store** that the `source` label names:

```bash
case "$source" in
    environment) printf '%s' "${!name:-}" ;;                                  # lib/registry.sh:271
    deployment)
        store=$(_cloudify_deployment_config) || store=""
        _cloudify_vars_store_get "$store" "$name"                              # lib/registry.sh:272-275
        ;;
    package) _cloudify_vars_store_get "$(cloudify_vars_pkg_file "$pkg")" "$name" ;;  # lib/registry.sh:276
    global)  _cloudify_vars_store_get "$(cloudify_vars_global_file)" "$name" ;;      # lib/registry.sh:277
    *) return 1 ;;
esac
```

This is the second walk. The value was already resolved once, at the single
export decision inside `_cloudify_vars_emit` during `cloudify_context_build`
(`lib/vars.sh:186-195`), but the resolved literal was deliberately *not* written
to the context file (metadata-only invariant #8). To write the record, this
function walks back to `cloudify_vars_pkg_file` / `cloudify_vars_global_file` /
`_cloudify_deployment_config` and reads the store a second time via
`_cloudify_vars_store_get` (`lib/vars.sh:454-462`).

The second-walk hazard, concretely:

- **Store drift.** If the store file changes between dispatch (context build)
  and the registry write (after the backgrounded `cloudify_remote_sync` finishes),
  the re-read value differs from what the payload actually forwarded. The record
  and the payload then disagree, violating invariant #9.
- **Absent vs present-but-empty is not distinguishable.** `_cloudify_vars_store_get`
  (`lib/vars.sh:454-462`) returns rc 0 with empty output for BOTH "key absent"
  and "key present with empty value" (`KEY:`). So a `literal`-form name whose
  value is a legitimately present-but-empty store value (which correctly claimed
  the name per invariant #5) gets re-read as empty in the record — the record
  cannot tell that the empty value was intentional.
- **The `reference` form is handled (verbatim `@backend:locator`,
  `lib/registry.sh:262-269`), but the `literal` form is not stored at all**, so
  the only way to recover it is the re-read. The context file has a
  `value.<NAME>.digest` for literal secrets (`lib/context.sh:337-340`), but no
  literal value, so nothing can be verified against the re-read.

The recovery must make the record's raw value come from the same single
resolution the payload used — e.g. capture the raw literal (or a replayable
reference) at `_cloudify_vars_emit` time and carry it through the context (or a
sibling provenance channel) so `cloudify_registry_record_build` never re-opens a
store. This is the Phase 2 fix.

---

## What a safe Phase 2 fix may and may not touch

### Files/functions a fix may touch

- `lib/registry.sh`:
  - `_cloudify_registry_context_raw` (`lib/registry.sh:260-278`) — the second walk.
  - `cloudify_registry_record_build` (`lib/registry.sh:298-368`) — the consumer
    that must read the raw value from the single resolution instead.
  - Possibly the context schema consumer in `_cloudify_registry_record_bg`
    (`lib/registry.sh:388-419`) if the carried raw value changes where it lives.
- `lib/context.sh`:
  - `cloudify_context_build` (`lib/context.sh:181`) and its write block
    (`lib/context.sh:322-346`) — to carry each declared name's resolved runtime
    form plus its provenance, per `REDESIGN.md:208` and `:302`. The file stays
    0600 and stays ephemeral; plaintext is permitted here and forbidden in logs,
    state, runs and events.
  - `_cloudify_vars_sources_record` consumers if the provenance shape changes.
- `lib/vars.sh`:
  - `_cloudify_vars_emit` (`lib/vars.sh:163-196`) and
    `_cloudify_vars_sources_record` (`lib/vars.sh:73-77`) — the single export
    decision is the only correct place to capture the raw value alongside the
    label, so the record never re-reads a store.

### Files/functions a fix must NOT touch (without re-asserting the gate)

- `lib/remote.sh`: `cloudify_remote_payload_template` (lines 24-77), the
  `declare -f` extraction (line 234), the envsubst allow-list (lines 241-242),
  the pkg_exports injection (lines 221-237), and the stdin payload send (lines
  270-274). These are the brittle forwarding core.
- `lib/shadows/*.sh` and `lib/shadow.sh`: all four shadow overrides and the
  loader. Any edit risks every one of the 75+ recipes.
- `lib/vars.sh` readers' *visit order and claim semantics*
  (`_cloudify_vars_claim`, `cloudify_vars_deployment_read`,
  `cloudify_vars_pkg_read`, `cloudify_vars_global_read`, `cloudify_vars_env_read`):
  the ladder order and first-write-wins must not change.
- The router (`cloudify`) dispatch/wait-loop metadata plumbing
  (`_cloudify_note_bg` at `cloudify:183-193`, the wait loop at
  `cloudify:807-824`) except as strictly required to point the registry writer at
  the new raw-value channel.

### Invariants to re-assert after the fix

Re-run and re-assert invariants #1, #2, #4, #5, #9, and #10 above, and
specifically:

1. The record's `var.<NAME>` equals the payload's forwarded value for every
   declared name, for every source label (environment, deployment, package,
   global, recipe), including the present-but-empty store value.
2. The context file is 0600, is removed exactly once, and no plaintext or
   resolved value from it reaches a log, a manifest, package state, a run record
   or an event. (Invariant #8 as superseded by design.)
3. The context path still never appears in `ps`/ssh argv, and cleanup still
   happens exactly once (success / failure / self-created).
4. The envsubst allow-list still substitutes exactly the names it should. If a
   phase adds a name (for example the Phase 4 frame nonce), that phase must state
   the addition and re-prove byte-identical payloads for the unchanged inputs;
   the "allow-list unchanged" wording holds only while no phase has added one.
