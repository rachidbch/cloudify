# State model v2 - CRITICAL GATE description of Cloudify's brittle Bash mechanisms

Artifact of the G1 description phase for the plan now archived at `plans/archived/state-model-v2-attempt1.md`. Written
READ-ONLY from the code at commit `e46689d`, before any edit under `lib/`, the
router, `pkg/`, or `tests/`. No source file was modified, created, or deleted.
It does NOT approve any change and it proposes none: G2 is the non-breakage
argument, G3 is human consent.

## 1. Scope, method, and how claims were verified

Scope: the two mechanisms named in `cloudify/AGENTS.md` - remote value
forwarding plus the `envsubst` payload (`lib/remote.sh`, `lib/vars.sh`) and the
shadow commands (`lib/shadows/*.sh`); plus everything the G1 acceptance list in
the archived attempt plan names: the router, targets, registry, deployments,
runbook engine, and the dependency/verify paths.

Method: every load-bearing claim carries a `file:line` citation. Claims that
could not be settled by reading were probed with short local scripts in
`~/tmp/state-model-v2-probes/` (section 9); no probe touched a host, ran incus,
called ivps, or installed anything. Quoted text is the literal code text
wherever the exact text is the claim.

Probes were run with GNU bash 5.1.16 and envsubst (GNU gettext-runtime) 0.21.
Probe 1 through 11 all ran and all outputs are recorded in section 9.

No dispatch was executed over SSH: the remote half of the chain is proven by
capturing the generated payload with a stubbed `ssh` (probe 7), not by a live
remote run. That is the largest single limitation and is listed in section 10.

Review: this draft was checked against `~/AGENTS.md` (lean prose, one claim per
line, no em dashes, no tables, no promises) and against the `cloudify-dev` skill
(collector-export channel, stdin transport, precedence ladder, shadow exit-code
warning, registry-as-observation, harness rules). The AGENTS.md registry rule
(registry observation-only, never a precedence source) is restated in section 7
and section 8 and matches the code.

## 2. Value flow end to end

### 2.1 Declarations: `.remote-vars`

A package declares forwarded names in `pkg/<pkg>/.remote-vars`, read at
`lib/vars.sh:223`. Three declaration shapes are recognised by regex at
`lib/vars.sh:229` (`^([A-Z_][A-Z0-9_]*)=(.*)$`) and `lib/vars.sh:232`
(`^([A-Z_][A-Z0-9_]*)$`): `NAME` = required, `NAME=` = optional,
`NAME=value` = defaulted with `value` as a human mirror only.
The mirror value is never exported: it is assigned to a local `mirror` at
`lib/vars.sh:230` and only used to pick the `kind`; the recipe's own
`${VAR:-default}` remains runtime truth (`pkg/xfce/.remote-vars:2-3`).
Names must be uppercase: the regexes at `lib/vars.sh:229/232` reject lowercase,
so a lowercase recipe var can never be declared or forwarded.
The same three shapes are re-implemented in `_cloudify_registry_declared_names`
at `lib/registry.sh:238/240` (which only needs the name) and in
`cloudify_vars_declared` at `lib/vars.sh:465/468` (the display surface).
The declaration file is read at `lib/vars.sh:223` and
`lib/registry.sh:233`.

### 2.2 The five value sources and the claim ledger

Every module carries a `_CLOUDIFY_X_LOADED` guard and returns early when it is
set: `lib/vars.sh:13-16` (`_CLOUDIFY_VARS_LOADED`), `lib/remote.sh:6-7`
(`_CLOUDIFY_REMOTE_LOADED`), `lib/shadow.sh:5-6` plus one guard per shadow file
(`lib/shadows/sudo.sh:5-6` and siblings), `lib/registry.sh:24-25`,
`lib/runbooks.sh:38-39`, `lib/deployments.sh:7-8`.

The ladder, weakest to strongest, is stated at `lib/remote.sh:84-89` and
`lib/vars.sh:5-8`: recipe default < global < package < deployment < caller env.

The walker is `_cloudify_pkg_remote_vars` (`lib/remote.sh:93`). It sets two
mechanisms for the duration of the walk:
`_CLOUDIFY_VARS_LEDGER` (a temp file, `lib/remote.sh:100-103`, path under `/tmp`
via `mktemp /tmp/cloudify-pkg-vars-XXXXXX`) and `_CLOUDIFY_VARS_DECLARED`
(`lib/remote.sh:102-104`).
A RETURN trap removes both, guarded on `FUNCNAME[0]` so a nested return under
`set -T` does not delete the ledger mid-walk (`lib/remote.sh:105-108`).

Claiming is `_cloudify_vars_claim` (`lib/vars.sh:51-59`): with a ledger set it
greps the ledger for an exact line and returns 1 when the name is already
claimed; otherwise it appends the name and returns 0. With no ledger set it
always returns 0, which is the legacy direct-call mode (`lib/vars.sh:53-54`).

The file-value sink is `_cloudify_vars_emit` (`lib/vars.sh:96-118`).
Order inside it: reserved-name guard (`:98-101`), claim (`:102`), optional name
print to stdout (`:103`), then the caller-env preservation check
(`:106-108`): when a ledger is set, the mode is `no-clobber`, and the name is
already non-empty in the caller env, the function returns without exporting.
Only then does it resolve the raw value (`:109-112`) and `export` it (`:113`).

The walk order in `_cloudify_pkg_remote_vars`:
deployment store first (`lib/remote.sh:126-129`, via `cloudify_vars_deployment_read`),
then each named package rightmost-CLI-first with its dependencies
(`lib/remote.sh:131-156`), then the global file (`lib/remote.sh:158-159`), then
the caller env over the candidate name set (`lib/remote.sh:161-178`).
Because every file reader runs in `no-clobber` mode, the caller env can never be
overwritten even though it is visited last (`lib/vars.sh:106-108`); probe 3
case A shows the env value winning while all four stores are populated.
The consequence is that "first claim wins" decides only between file sources,
and the visiting order above is exactly the ladder.

Per-source readers:
global: `cloudify_vars_global_read` (`lib/vars.sh:200-205`) over
`$(cloudify_vars_config_dir)/remote-vars.yaml` (`lib/vars.sh:149-151`).
package: `cloudify_vars_pkg_read` (`lib/vars.sh:217-249`): the declaration mirror
is scanned first and a declared name is claimed only when the caller env already
has a non-empty value (`lib/vars.sh:240-244`), then the per-package yaml
`$(cloudify_vars_config_dir)/pkgs/<pkg>.yaml` is read in `no-clobber` mode
(`lib/vars.sh:248`).
deployment: `cloudify_vars_deployment_read` (`lib/vars.sh:259-279`) over
`$(_cloudify_deployment_config <id>)/config.yaml`, keys matching
`^[A-Za-z_][A-Za-z0-9_]*$` (`lib/vars.sh:275`), each line emitted `no-clobber`
(`lib/vars.sh:277`).
global and package yaml keys are uppercase-only (`lib/vars.sh:133`); the
deployment file allows mixed case (`lib/vars.sh:275`); `.remote-vars` names are
uppercase-only (`lib/vars.sh:229/232`).
caller env: `cloudify_vars_env_read` (`lib/vars.sh:314-326`) claims and
re-exports only names passed to it; those names are the declared names recorded
during the walk (`lib/remote.sh:162-171`).

The candidate-name gate: `_cloudify_vars_env_read` is called only with declared
names (`lib/remote.sh:166-171`), so an ambient environment variable no source
mentions is never claimed and never enters the payload; probe 3 case G shows
`AMBIENT` absent from the claimed-name list while `GLOBALONLY` and `ONLY_ENV`
are present. The same gate exists for file stores: only names held in a store
or declared for the package are read (README.md:186-190).

After the walk, `_cloudify_pkg_remote_vars` prints the sorted, deduplicated
claimed names (`lib/remote.sh:184`, `sort -u "$TMPFILE"`).

A declared required name that no source provides is warned about, not fatal
(`lib/remote.sh:172-177`, only when kind is `required`); optional and defaulted
names are silent.

### 2.3 Secret references

`_cloudify_resolve_var_value` (`lib/vars.sh:74-94`) is the only resolver.
`@@x` unescapes to `@x` (`:76-79`); a value not starting with `@` passes through
(`:80-83`); otherwise it must split as `@<backend>:<locator>` with non-empty
parts (`:84-92`) and is dispatched to `cloudify_secret_resolve`
(`lib/secrets.sh:31-44`), which looks up `cloudify_secret_backend_<backend>`
(`lib/secrets.sh:33-37`) and fails on unknown backend or backend failure.
The built-in backend is base64 (`lib/secrets/base64.sh:7-15`).
On any failure `_cloudify_vars_emit` dies with "cannot resolve value - refusing
to forward an empty value" (`lib/vars.sh:110-112`).
Probe 8 confirms: plain identity, `@@literal` unescape, base64 round-trip
including a newline, and rejection (rc 1) of `@`, `@nosuch:loc`, `@nocolon`,
`@:loc`, and `@back:`.

Resolution is applied only where a raw value is read from a store
(`_cloudify_vars_emit`). The caller-env reader exports `${!name}` verbatim
(`lib/vars.sh:322`), and the `.remote-vars` declared-name branch does the same
(`lib/vars.sh:243`). So a `@base64:...` reference placed in the caller
environment is forwarded as that literal reference string and is NOT decoded;
probe 7 shows the payload line
`export CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD='@base64:YWRtaW4tc2VjcmV0'`.
The replay path explicitly re-resolves snapshot values before exporting them
because "the env path is a pass-through" (`lib/runbooks.sh:887-891`).
This env/file asymmetry is load-bearing for G2.

Multiline values cannot live on one `KEY: value` line, so `_cloudify_vars_file_set`
stores them as `@base64:` (`lib/vars.sh:186-188`); the reader then decodes them
via the resolver. A value starting with `@` must be a valid reference or the
`@@` escape, and an unknown backend is rejected at write time
(`lib/vars.sh:177-185`).

### 2.4 Framework-owned names

`_CLOUDIFY_VARS_RESERVED` (`lib/vars.sh:28-39`) lists `CLOUDIFY_REMOTE_USER`,
`CLOUDIFY_REMOTE_PWD`, `DEBUG`, `CLOUDIFY_BOOTSTRAP_URL`,
`CLOUDIFY_UPDATE_DELAY`, `CLOUDIFY_FORCE`, `CLOUDIFY_NO_VERIFY`,
`CLOUDIFY_DEPLOYMENT`, `CLOUDIFY_NODE`, `CLOUDIFY_INSTANCE`.
`_cloudify_vars_reserved` is an exact-match loop (`lib/vars.sh:41-49`).
A file store that tries to set one is warned about and skipped
(`lib/vars.sh:98-101`; probe 8 shows `DEBUG` kept as `false` with the warning).
`HOME`, `PATH`, `USER`, and `CLOUDIFY_LOG_FILE` are NOT reserved; see 3.4.

### 2.5 There is no applied-state reader

`cloudify_vars_state_read()` is a stub that only `return 0`
(`lib/vars.sh:504-506`), and `tests/unit/vars.bats:46-50` pins it as a no-op.
No module reads registry records into the ladder: the only registry readers are
`cloudify_registry_get` used inside `cloudify_registry_record_build`
(`lib/registry.sh:277`) and the writer path, and `lib/vars.sh` contains no
reference to the registry. So the current value channel is the five sources
above only; v2's applied state has no reader yet.

### 2.6 Worked example: `guacamole`, one value from declaration to the remote env

Package: `pkg/guacamole`. Declared names (`pkg/guacamole/.remote-vars:4-8`):
`CLOUDIFY_GUACAMOLE_DB_PASSWORD` (required),
`CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD` (required),
`CLOUDIFY_GUACAMOLE_RDP_PASSWORD` (required),
`CLOUDIFY_GUACAMOLE_RDP_HOST` (required),
`CLOUDIFY_GUACAMOLE_ADMIN_USER=guacadmin` (defaulted mirror only).
The recipe consumes many more names (`pkg/guacamole/install.sh:51-60`), all of
which are undeclared and therefore never forwarded; they stay at the recipe's
`${VAR:-default}` on each host.

Trace of `CLOUDIFY_GUACAMOLE_DB_PASSWORD`:
1. Declaration: `pkg/guacamole/.remote-vars:4`, bare name = required.
2. Operator stores it in the desired-input store:
   `cloudify vars set CLOUDIFY_GUACAMOLE_DB_PASSWORD --stdin --deployment xfce-gui`
   (router `cloudify:546-562`) writes a flat `KEY: value` line via
   `_cloudify_vars_file_set` (`lib/vars.sh:170-196`) into
   `~/.config/cloudify/deployments/xfce-gui/config.yaml` (`lib/vars.sh:281-287`).
3. The runbook engine exports `CLOUDIFY_DEPLOYMENT=xfce-gui` for the whole run
   (`lib/runbooks.sh:641`) and runs the step body
   `cloudify --on "$TARGET_GATEWAY" install guacamole`
   (`runbooks/xfce-guacamole/disposable.md:79-81`), so the child router inherits
   the deployment id.
4. The child resolves the target to `<node>\t<gateway>\t<gateway>`
   (`lib/targets.sh:74-151`) and dispatches (`cloudify:303-366`).
5. Remote branch: `cloudify_remote gateway install guacamole`
   (`cloudify:358`, `lib/remote.sh:188-192`) backgrounds
   `cloudify_remote_sync` (`lib/remote.sh:195`).
6. `cloudify_remote_sync` runs the walker in its own shell:
   `_cloudify_pkg_remote_vars "$@" > "$_pkg_vars_list"`
   (`lib/remote.sh:216-220`). The walker reads the deployment store
   (`lib/remote.sh:126-129`), `cloudify_vars_deployment_read` sees the
   `xfce-gui` config, and `_cloudify_vars_emit` claims and exports
   `CLOUDIFY_GUACAMOLE_DB_PASSWORD` (probe 3 is the mechanism proof).
7. The walker prints the claimed names; `cloudify_remote_sync` turns each
   into `pkg_envsubst=" $NAME"` and an `export NAME='$NAME'` fragment
   (`lib/remote.sh:221-230`).
8. The payload template body is extracted with
   `declare -f cloudify_remote_payload_template | tail -n +3 | head -n -1`
   (`lib/remote.sh:234`); the placeholder `_CLOUDIFY_PKG_EXPORTS_`
   (`lib/remote.sh:50`) is replaced by the fragments (`lib/remote.sh:237`).
9. envsubst substitutes the allow-listed names (`lib/remote.sh:241-243`),
   producing `export CLOUDIFY_GUACAMOLE_DB_PASSWORD='<plaintext>'` inside the
   payload (probe 7 line 27).
10. The payload is written mode 0600 to `$CLOUDIFY_TMP/cloudify-payload-XXXXXX`
    and piped to `ssh <user>@<host> 'bash -s' < "$payload_file"`
    (`lib/remote.sh:269-274`). No value is ever in ssh argv (probe 7).
11. The remote bash runs the export line, then
    `:; cloudify install guacamole </dev/null` (`lib/remote.sh:246`) in the same
    process, so the router and `pkg_depends` inherit the variable.
12. `cloudify_install_package guacamole` (`lib/packages.sh:259-279`) calls
    `pkg_depends guacamole` (`lib/package-api.sh:397`), which sources the
    install phase in a subshell (`lib/package-api.sh:423`,
    `lib/package-api.sh:383-394`); `pkg/guacamole/install.sh:42` reads
    `${CLOUDIFY_GUACAMOLE_DB_PASSWORD:-}` and dies when empty, then writes it
    into `$HOME/guacamole/.env` (mode 600, `pkg/guacamole/install.sh:97-123`).

## 3. Dispatch and transport

### 3.1 Router parsing

`main()` (`cloudify:370`) parses flags first (`cloudify:405-764`).
`--on` enters a host block (`cloudify:665-714`): each token is resolved by
`_cloudify_target_resolve` into a `<node>\t<instance>\t<ssh_host>` triple
(`cloudify:697-703`), the ssh host is appended to the space-separated `hosts`
string (`cloudify:704-708`), and the triples are kept in `_CLOUDIFY_TARGETS`
(`cloudify:703`, declared `cloudify:399`) for the registry record.
Resolution runs with a redirect into a temp file, never `$(...)`, so a bad
target dies in the router shell (`cloudify:691-697`).
An action word (`install|uninstall|configure|verify` and aliases,
`cloudify:715-761`) defaults `hosts=localhost` and appends the localhost triple
when no `--on` was given (`cloudify:717-720`), then accumulates package words
into the `packages` string (`cloudify:758`).
The package word list is re-split with `read -ra` at dispatch
(`cloudify:347-349`).

`_cloudify_dispatch` (`cloudify:303`) decides local vs remote by the whole
`hosts` string: `if [[ "$hosts" == "localhost" ]]` (`cloudify:328`,
`cloudify:342`). A local target is dispatched through
`_cloudify_execute_package_action`; anything else, including a mixed list that
happens to contain localhost, goes through `cloudify_remote` over SSH
(`cloudify:350-364`).

### 3.2 Targets

The grammar and its validation live in `lib/targets.sh:1-10` and the resolver at
`lib/targets.sh:74-151`: `X` bare discovers the kind and fails closed when the
name is both a node and an instance (`lib/targets.sh:129-147`); `X:` is a node
(`lib/targets.sh:90-92`, `:114-117`); `X:Y` is an instance on X
(`lib/targets.sh:119-126`); `:Y` uses `CLOUDIFY_NODE` then the ivps default
(`lib/targets.sh:93-96`, `:104-108`), reading `IVPS_DEFAULT_NODE` from the ivps
config file (`lib/targets.sh:59-68`). `localhost` maps to node `local`
(`lib/targets.sh:79-82`); a node target's ssh host is `localhost` for node
`local` and the node name otherwise (`lib/targets.sh:47-50`); an instance target
uses the instance name as the ssh host (`lib/targets.sh:125`). Anything the
ivps inventory does not know stays a plain host whose ssh host is the token
(`lib/targets.sh:149-150`). Resolution never provisions; the helpers only read
`ivps node path` and `ivps list` (`lib/targets.sh:24-45`).

### 3.3 Background dispatch, pid and exit-code accounting

`cloudify_remote` backgrounds one `cloudify_remote_sync` subshell per host and
records `$!` in `_CLOUDIFY_BG_PIDS` and its host in `_CLOUDIFY_BG_HOSTS`
(`lib/remote.sh:188-192`). Local actions are backgrounded in the router:
user-requested install (`cloudify:263-266`), configure (`cloudify:270-273`),
uninstall (`cloudify:278-281`), verify (`cloudify:285-296`).
Per-pid metadata for the later registry write is stored by `_cloudify_note_bg`
(`cloudify:179-184`) into `_CLOUDIFY_BG_ACTION/_PKGS/_TARGET`
(declared `cloudify:394-396`); remote dispatch reads `$!` after
`cloudify_remote` returns to key that metadata (`cloudify:358-363`).
For a local dispatch the current target triple is passed in
`_CLOUDIFY_CUR_TARGET` (`cloudify:344`, fallback `local\t\tlocalhost` at
`cloudify:266`).

`main()`'s tail waits on every pid: `wait "$_bg_pid" && _bg_rc=0 || _bg_rc=$?`
(`cloudify:778`), prints OK/FAILED, and on success calls
`_cloudify_registry_record_bg "$_bg_pid"` (`cloudify:779-786`); any failure
exits 1 with the log path (`cloudify:789-791`). So the exit-code accounting is
`wait`, and registry writes happen only for a pid whose wait returned 0.

`cloudify_remote_sync` also writes the exit code to `$CLOUDIFY_TMP/<host>.exit`
(`lib/remote.sh:206` for localhost, `lib/remote.sh:280` for SSH). The router only
deletes that file at dispatch start (`cloudify:327`, `cloudify:341`); nothing in
`lib/` or `cloudify` reads it, so it is a write-only diagnostic artifact
(only `tests/unit/remote.bats:65-76` and `tests/unit/remote-stdin.bats:57`
assert its content).

### 3.4 Payload construction

`cloudify_remote_sync` (`lib/remote.sh:195-283`) is the transport.
The template is the function body of `cloudify_remote_payload_template`
(`lib/remote.sh:16-78`), extracted at `lib/remote.sh:234` as literal text with
no evaluation of the function. Probe 1 confirms `declare -f` emits a signature
line and a bare `{` first and a bare `}` last, so the extraction drops exactly
those three structural lines; the template's first extracted line is
`    export CLOUDIFY_IS_LOCAL=false;` and its last is `    :`.

The package export block is built at `lib/remote.sh:221-230` as
`    export <NAME>='$<NAME>'` per claimed name; the `$<NAME>` is written by the
local shell as literal text (`"\$$var"`), so envsubst is what fills it.
The block replaces the literal placeholder line `    : _CLOUDIFY_PKG_EXPORTS_;`
(`lib/remote.sh:50`, replacement `lib/remote.sh:237`); the replacement begins
with a newline, leaving a harmless trailing `;`.

envsubst runs once over the whole rendered payload with an explicit
SHELL-FORMAT allow-list (`lib/remote.sh:241-243`):
the fixed framework tokens `\$CLOUDIFY_DISABLE_COLORS`, `\$DEBUG`,
`\$CLOUDIFY_LOG_LEVEL`, `\$CLOUDIFY_NO_DEFAULTS`, `\$CLOUDIFY_CLEAR_DATA`,
`\$CLOUDIFY_FORCE`, `\$CLOUDIFY_NO_VERIFY`, `\$PKG_VERIFY_TIMEOUT`,
`\$CLOUDIFY_FORCE_UPDATE`, `\$CLOUDIFY_UPDATE_DELAY`, `\$CLOUDIFY_REMOTE_USER`,
`\$CLOUDIFY_REMOTE_PWD`, `\$CLOUDIFY_GITHUBUSER`, `\$CLOUDIFY_GITHUBPWD`,
`\$CLOUDIFY_GITHUB_READONLY_TOKEN`, `\$CLOUDIFY_GITLABUSER`,
`\$CLOUDIFY_GITLABPWD`, the five rclone variables, `\$RESTIC_PASSWORD`,
`\$CLOUDIFY_BOOTSTRAP_URL`, `\$CLOUDIFY_LOG_BASENAME`, immediately followed by
`${pkg_envsubst}` with one ` $NAME` per claimed package name.
Everything else in the template is left for the remote shell to expand at
runtime, for example `$HOME` and `$(find ...)` in `lib/remote.sh:58`, or
`$(date +%Y%m%d-%H%M%S)` in `lib/remote.sh:68`.

envsubst is a name-substitution pass, not an evaluator: probe 2a shows an
unlisted `$HOME`, a `$(date)` and an unlisted `$CLOUDIFY_FORCE` survive verbatim.
Probe 2b shows a format token `$K3S` does NOT substitute the `K3S` prefix of an
input `$K3S_TOKEN` (envsubst matches the name greedily and then filters), so
prefix over-substitution is not the failure mode.
Probe 2c shows envsubst does not rescan text it has just inserted: a value
containing `$CLOUDIFY_FORCE`, inserted by substituting `$X`, is left literal
even though `$CLOUDIFY_FORCE` is also in the format.
The real over-substitution hazard is a claimed name that also occurs as
template text: probe 2e substitutes `$HOME` in
`export CLOUDIFY_LOCAL_BIN="$HOME/.local/bin"` when `$HOME` is in the
allow-list, and `HOME`/`PATH`/`USER` are not in `_CLOUDIFY_VARS_RESERVED`
(`lib/vars.sh:28-39`). A package that declares such a name would rewrite the
bootstrap lines too.

Single-quoted remote references: because each exported value is baked inside
single quotes, spaces, `$` and `$( )` stay literal on the remote. Probe 2d2
shows `X='a b $(id)'` evaluates to the single literal argument. Probe 2d shows
the flip side: a value containing a single quote escapes the quotes and the
remainder of the line executes, so the bake is not injection-safe. Recipes that
forward passwords guard against exactly this (`pkg/guacamole/install.sh:45-48`)
and the declaration file states the rule (`pkg/guacamole/.remote-vars:3`).

Debug rendering of the payload is best-effort masking, not a whitelist:
`lib/remote.sh:251-257` replaces `PWD`, `PASSWORD`, `SECRET`, `TOKEN` and `KEY`
patterns, and the rendered payload is printed only when `DEBUG` is true
(`lib/remote.sh:259`). A secret under another name prints in full, and the
unmasked payload is not written to disk by this code path, but the raw value is
in the process memory and in the SSH stdin stream.

Transport details: `cloudify_remote_sync` exports
`CLOUDIFY_LOG_BASENAME` so the remote log filename matches the local one
(`lib/remote.sh:210-212`), writes the payload to a mode-0600 temp file
(`lib/remote.sh:269-272`), and runs
`ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$user@$host" 'bash -s' < "$payload_file"`
(`lib/remote.sh:273-274`). Host-key checking is disabled; the code names the
MITM trade-off (`lib/remote.sh:262-265`).

Per-command stdin rule: the payload never issues a global `exec </dev/null`
(the only global redirect is stdout/stderr to the tee at `lib/remote.sh:76`).
Instead the appended command carries its own redirect
(`lib/remote.sh:246`, `cloudify $* </dev/null`) and the template uses
`bash -c "$(curl ...)" </dev/null` (`lib/remote.sh:60`) and
`cloudify init </dev/null` (`lib/remote.sh:73`). Probe 1 shows the extracted
template's last line is `:`, and `tests/unit/remote-stdin.bats:41-47` guards
this: no `2>&1 </dev/null`, presence of per-command redirects.

Remote bootstrap: when `$CLOUDIFY_FORCE_UPDATE` is true or
`$HOME/cloudify/.#last_update` is older than `CLOUDIFY_UPDATE_DELAY` minutes,
the payload installs git if needed and runs the pinned gist
(`lib/remote.sh:58-61`), whose URL is the gist raw URL set at `cloudify:72`.
The gist (fetched read-only for this description) does:
`git pull` in `$HOME/cloudify` when it exists, else
`git clone https://github.com/rachidbch/cloudify.git "$HOME/cloudify"`, touches
`.#last_update`, then installs `cloudify` as a symlink at
`/usr/local/bin/cloudify` (or `install -m 755` when the symlink fails), using
sudo with the password from `CLOUDIFY_HOSTPWD`. So the code a remote host runs
is the branch tip at pull time unless the update gate skipped the pull.
The payload follows the bootstrap with a log file under
`/tmp/cloudify/logs/<basename>` and a `latest.log` symlink
(`lib/remote.sh:62-72`), then `cloudify init </dev/null` (`lib/remote.sh:73`),
then the tee redirect (`lib/remote.sh:76`), then the appended command
(`lib/remote.sh:246`).

### 3.5 Exact runtime payload (probe 7, guacamole, secrets replaced)

Generated from the real code with a stubbed `ssh`; only the two literal secrets
are replaced by placeholders, everything else is byte-for-byte the captured
payload.

```
    export CLOUDIFY_IS_LOCAL=false;
    export CLOUDIFY_DISABLE_COLORS='true';
    export CLOUDIFY_FORCE_COLORS=true;
    export DEBIAN_FRONTEND=noninteractive;
    export NEEDRESTART_MODE=a;
    export CLOUDIFY_SKIPCREDENTIALS=true;
    export DEBUG='false';
    export CLOUDIFY_LOG_LEVEL='INFO';
    export CLOUDIFY_NO_DEFAULTS='';
    export CLOUDIFY_LOCAL_BIN="$HOME/.local/bin";
    export CLOUDIFY_LOCAL_USER='testuser';
    export CLOUDIFY_LOCAL_PWD='pwd';
    export CLOUDIFY_HOSTPWD='pwd';
    export CLOUDIFY_GITHUBUSER='';
    export CLOUDIFY_GITHUBPWD='';
    export CLOUDIFY_GITHUB_READONLY_TOKEN='';
    export CLOUDIFY_GITLABUSER='';
    export CLOUDIFY_GITLABPWD='';
    export CLOUDIFY_RCLONE_REMOTE='';
    export CLOUDIFY_RCLONE_REMOTE_REGION='';
    export CLOUDIFY_RCLONE_REMOTE_ENDPOINT='';
    export CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID='';
    export CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY='';
    export RESTIC_PASSWORD='';
    : 
    export CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD='@base64:YWRtaW4tc2VjcmV0'
    export CLOUDIFY_GUACAMOLE_DB_PASSWORD='<DB_PW>'
    export CLOUDIFY_GUACAMOLE_RDP_HOST='guest.example.ts.net'
    export CLOUDIFY_GUACAMOLE_RDP_PASSWORD='<RDP_PW>';
    export CLOUDIFY_CLEAR_DATA='';
    export CLOUDIFY_FORCE='';
    export CLOUDIFY_NO_VERIFY='';
    export PKG_VERIFY_TIMEOUT='';
    if 'false' || [[ -z "$(find $HOME/cloudify/.#last_update -mmin -'30' 2>/dev/null)" ]]; then
        command -v git > /dev/null 2>&1 || apt-get install -y -qq git;
        bash -c "$(curl -sL '')" < /dev/null;
    fi;
    mkdir -p /tmp/cloudify/logs;
    if [ -n '20260912-231106.log' ]; then
        CLOUDIFY_LOG_FILE="/tmp/cloudify/logs/20260912-231106.log";
    else
        CLOUDIFY_LOG_FILE="/tmp/cloudify/logs/$(date +%Y%m%d-%H%M%S).log";
    fi;
    export CLOUDIFY_LOG_FILE;
    : > "$CLOUDIFY_LOG_FILE";
    ln -sf "$CLOUDIFY_LOG_FILE" /tmp/cloudify/logs/latest.log;
    cloudify init < /dev/null;
    exec > >(tee -a "$CLOUDIFY_LOG_FILE") 2>&1;
    :; cloudify install guacamole </dev/null
```

Notes on this capture: `CLOUDIFY_BOOTSTRAP_URL` is empty because the probe did
not export it; the router always sets it (`cloudify:72`). The remote command
shows `cloudify install guacamole`, resolved through PATH, which the gist's
`/usr/local/bin/cloudify` symlink supplies.

The resolved allow-list for this example is the 25 fixed framework tokens listed
in 3.4 plus ` $CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD`,
` $CLOUDIFY_GUACAMOLE_DB_PASSWORD`, ` $CLOUDIFY_GUACAMOLE_RDP_HOST`,
` $CLOUDIFY_GUACAMOLE_RDP_PASSWORD`, in that sorted order
(`lib/remote.sh:184`, `lib/remote.sh:221-230`).

## 4. Shadows

`lib/shadow.sh:11-14` sources every `lib/shadows/*.sh` at router start
(`cloudify:106`). Each file has its own `_CLOUDIFY_SHADOW_*_LOADED` guard and
defines a function with the real command's name, so a bare recipe call resolves
to the shadow function (`lib/shadows/apt-get.sh:34`, `:81`;
`add-apt-repository.sh:17`; `git.sh:72`; `sudo.sh:12`). The real binary is
reached with `command <name>` (`lib/shadows/git.sh:37`, `:103`, `:118`, `:125`;
`sudo.sh:101`, `:109`).

### 4.1 `lib/shadows/sudo.sh`

- Interception: `sudo()` (`:12`) fetches the password through
  `cloudify_get_password` into `password/user/host` (`:16-18`), which reads
  `CLOUDIFY_HOSTPWD` (`lib/utils.sh:292-303`).
- Invariant: a missing password dies; recipes never prompt
  (`lib/shadows/sudo.sh:18`).
- Arg handling special cases: `add-apt-repository` gets its args wrapped in
  single quotes (`:22-25`), `sed` gets its expression quoted and the file left
  bare (`:26-50`), `find` escapes `;` (`:51-67`), everything else is re-joined
  with spaces (`:68-70`).
- Invariant: stdin is freed for the password. The shadow classifies stdin as
  terminal, pipe (`[[ -p /dev/stdin ]]`), `/dev/null` (`[[ /dev/stdin -ef /dev/null ]]`),
  or heredoc/redirect (`:75-85`), captures piped/redirected input into
  `pipeargs` (`:79`, `:84`), and rebuilds `echo '<pipeargs>' | <lineargs>` when
  there is piped input (`:87-92`).
- Invariant: a command with piped input must tolerate being re-joined as a
  single `bash -c` string; data piped through sudo is re-emitted by `echo`
  (`:91`), so a value containing a single quote breaks it.
- Execution: `command sudo -kS -p "" bash -c "$sudocmd" <<<"$password"`
  (`:101`); for a command string at or above 10000 characters a different path
  writes `pipeargs` to a temp file and calls `sudo ... "$lineargs" "$tfile"`
  (`:96-110`), which changes the command shape.
- Exit code: the function returns the real sudo exit status (last statement at
  `:101` or `:109`); it does not swallow.

### 4.2 `lib/shadows/apt-get.sh`

- Interception: `apt-get()` (`:34`) and its alias `apt()` (`:81`).
- Invariant: idempotency. `_cloudify_pkg_installed` greps
  `dpkg -l <name>` for `^ii  <name>` (`:16-19`); an installed package is
  skipped with a debug line (`:58-59`), and a `.deb` path is reduced to its
  package name (`:22-29`).
- Invariant: the cache is refreshed only when a requested package is genuinely
  missing AND the cache is stale.
  `_cloudify_apt_cache_stale` is true when `pkgcache.bin` is absent or older
  than 60 minutes (`:9-13`); the pre-pass sets `need_install` (`:42-50`) and the
  update runs only when both hold (`:51-53`); `update` also accepts an explicit
  `--force` (`:65-70`).
- Invariant: non-interactive: installs always pass `-y` (`:61`) and route
  through `sudo apt-get -qq install` (`:61`).
- Exit-code swallowing (probe 9): the install loop runs each package in turn
  (`:55-63`), so a failure of package N is invisible when a later package
  succeeds; the function's status is the last iteration's status. Probe 9 shows
  `apt-get install -y b a` returning 0 although `b` failed, and `a b` returning
  100 because `b` was last.
- Pass-through: `remove|purge` and any other subcommand go straight to
  `sudo apt-get "$@"` (`:71-76`).

### 4.3 `lib/shadows/add-apt-repository.sh`

- Interception: `add-apt-repository()` (`:17`).
- The repository spec is the last non-flag argument (`:20-22`); a `ppa:`
  prefix is stripped for the presence check (`:23-24`).
- Invariant: idempotency via `_cloudify_repo_present`, which greps
  `^deb .*<spec>` in `/etc/apt/sources.list.d/*` (`:9-12`); a present repo is a
  no-op with a debug line (`:25-26`).
- On a change it runs `sudo add-apt-repository "$repo_spec" -y` then
  `apt-get update --force` (`:28-29`), so the refresh is delegated to the
  apt-get shadow.
- Exit-code swallowing: the function's status is the refresh's status when a
  change happened, and `PKG_DEBUG`'s status when nothing changed; a failing
  `sudo add-apt-repository` is masked when the following update succeeds.

### 4.4 `lib/shadows/git.sh`

- Interception: `git()` (`:72`); `clone` takes a dedicated branch (`:76-121`),
  every other subcommand takes `:122-144`.
- Invariant: authentication is per-domain.
  `cloudify_git_authenticate` backs up `$HOME/.gitconfig` with `pkg_backup`
  (`:14`), sets `GIT_TOKEN` from `CLOUDIFY_GITLABPWD` for gitlab.com or from
  `CLOUDIFY_GITHUB_READONLY_TOKEN` then `CLOUDIFY_GITHUBPWD` for github.com
  (`:20-30`), writes an askpass script that echoes the token (`:32-34`), and
  rewrites remote URLs with `insteadOf` so ssh-style URLs go over https
  (`:37-39`). Unknown domains die (`:29`).
- Invariant: the `.gitconfig` mutation is undone after the real command by
  `cloudify_git_deauthenticate` -> `pkg_restore` (`:43-46`, called at `:120`,
  `:143`).
- Invariant: clone into an existing non-empty directory becomes a pull, and
  only when the origin matches the requested URL (`:98-113`); a different origin
  is refused (`:111`). Without credentials a non-clone command is a plain
  pass-through returning the real status (`:123-127`).
- Exit-code swallowing (probe 10): in the clone branch a failing
  `command git "$@" -v` (`:118`) is followed by `cloudify_git_deauthenticate`;
  the function's status is the deauthentication status, so a failed clone can
  return 0. Probe 10 shows a fake `git clone` exiting 3 and the shadow returning
  0 with credentials present and absent (the clone branch always authenticates).
  The pass-through path for a non-clone without credentials returns the real 4.
- `cloudify_git_same_remote` compares domain, account and project parsed by
  `cloudify_parse_git_url` (`:49-69`).

Recipes therefore depend on these shadow invariants: bare `apt-get install`,
`add-apt-repository`, `sudo` and `git clone` are safe to call without guarding
idempotency (`lib/shadows/apt-get.sh:9-63`,
`lib/shadows/add-apt-repository.sh:9-30`); `sudo` needs a password in
`CLOUDIFY_HOSTPWD` (`lib/shadows/sudo.sh:16-18`); and any shadow invocation can
return a status that reflects a later internal step, so a postcondition check is
required where the recipe cares (this is the "shadow installers can swallow exit
codes; assert postconditions" rule in the `cloudify-dev` skill).

## 5. Runbooks

Types and the machine contract are at `lib/runbooks.sh:1-35` and `:41-43`:
step types `launch install configure verify uninstall run human-gate`, of which
`install configure verify uninstall` consume a package and declare required
vars (`lib/runbooks.sh:43`).

Parsing:
- Front matter is the lines between the first two `---`
  (`_cloudify_runbook_frontmatter`, `lib/runbooks.sh:160-174`), parsed for
  `deployment` and `targets` (`lib/runbooks.sh:179-213`); a missing
  `deployment:` is fatal (`lib/runbooks.sh:192`), and targets are split on comma
  or space, deduplicated, in declaration order (`lib/runbooks.sh:194-211`).
- `cloudify_runbook_parse` walks the file, tracking fenced blocks
  (`lib/runbooks.sh:306-334`); a fence whose info string is not `bash step=...`
  is ignored (`lib/runbooks.sh:240`). The info string's first token is `bash`,
  the second must be `step=<type>` (`lib/runbooks.sh:240-244`); the remaining
  tokens are `target=`, `pkg=`, `id=` and anything else dies
  (`lib/runbooks.sh:246-255`). Package types require `pkg=`
  (`lib/runbooks.sh:262-264`); every type except `human-gate` and `run` requires
  `target=` (`lib/runbooks.sh:259-261`); a target must be declared in the front
  matter (`lib/runbooks.sh:265-267`); ids default to the 2-digit index of the
  fenced block and must be unique (`lib/runbooks.sh:269-271`, index incremented
  per fenced block at `:327`). Each step is one tab-separated
  line `type\tid\ttarget\tpkg\tbody-b64` (`lib/runbooks.sh:273-274`), the body
  base64-encoded so a multi-line shell body survives (`:34-35`).
- `cloudify_runbook_find` requires exactly one runbook whose front matter
  declares the id (`lib/runbooks.sh:340-356`).

Target binding: `cloudify_runbook_bind_targets` (`lib/runbooks.sh:363-422`)
collects `--target name=addr` (`:369-379`), rejects a binding for an undeclared
name (`:392-399`), and for every declared target takes the CLI binding, else the
deployment-store var `TARGET_<NAME>` uppercased (`:404-407`);
an unbound target is collected and the function dies listing all of them
(`:408-419`). Each address goes through `_cloudify_target_resolve` (`:413`),
which dies fail-closed on an unknown or ambiguous address. Output is
`name\tnode\tinstance\tssh_host` (`:421`).

Preflight: `cloudify_runbook_preflight` (`lib/runbooks.sh:429-478`) binds
targets first (`:438`, a harder failure than a missing var, `:437`), exports
`CLOUDIFY_DEPLOYMENT` so the deployment store participates in the source check
(`:440-442`), parses the steps (`:445`), and for every package step reads
`pkg/<pkg>/.remote-vars` (`:459`) and checks each bare required name
(`NAME=/value` lines are skipped, `:464-465`) with `_cloudify_vars_source_of`
(`:467`); `recipe-default` means unresolved and all missing names are listed in
one fatal message (`:468-477`).

Execution: `cloudify_runbook_execute` (`lib/runbooks.sh:593-800`).
- Preflight runs before any step (`:626-627`).
- Run-wide exports: `CLOUDIFY_DEPLOYMENT` (`:641`), `TARGET_<NAME>` for every
  bound target as the reconstructed address `node[:instance]` or the plain ssh
  host (`:643-655`, `_cloudify_runbook_target_addr` `:85-90`).
- Outputs channel: a 0600 temp file exported as `CLOUDIFY_OUTPUTS_FILE`
  (`:657-660`).
- Snapshot values: by default the deployment store's raw lines become
  `value.<KEY>: <raw>` (`:676-687`); when `CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES` is
  set, the `value.*` lines of that snapshot are carried instead (`:668-675`),
  which is how a replay stays replayable after the store changes
  (`:661-665`, `:27-30`).
- Steps: the parsed list is read into an array before the loop so a step body's
  own `read`/`cat` cannot consume the remaining steps (`:700-704`); this fixed a
  truncation bug documented at `:700-703`.
- Per step: `STEP_ID/STEP_TYPE/STEP_TARGET/STEP_PKG` are exported (`:722`),
  `human-gate` prints the body and either requires a TTY plus `y` or fails, or
  passes when `--yes` (`:724-741`), and every other step runs
  `bash -c "$body" </dev/null` (`:744`); a nonzero rc sets `status=failed` with
  the step id and rc (`:745-748`).
- Output ingestion: after each step the outputs file is read from the
  previously consumed line offset (`tail -n +$((outputs_consumed + 1))`,
  `:751-764`), each valid `name=value` becomes `OUT_<name>` in the run
  environment (`:758`) and is recorded once in a run-ordered list (`:759-762`);
  ingestion also happens on failure (`:750`).
- Failure handling: the first failing step breaks the loop (`:766`), the
  snapshot is still written (`:771-789`), the outputs file is removed and the
  step exports are unset (`:791-792`), and the function dies with the failure
  message (`:794-796`).
- Snapshot: `$CLOUDIFY_DEPLOYMENTS_DIR/<deployment>/runs/<UTC>.yaml`
  (`:772-776`), never overwriting an existing name, suffixing `-2`, `-3`
  (`:777-784`), written through a 0600 mktemp plus `mv` (`:785-789`), with
  fields `status`, `started_at`, `finished_at`, `runbook`, `target.<name>`,
  `value.<NAME>`, `output.<name>` (`_cloudify_runbook_snapshot`, `:96-112`).
  So the snapshot currently persists step outputs, which v2 Phase 5 intends to
  stop.

Replay: `cloudify_deployment_replay` (`lib/runbooks.sh:812-925`) selects a
snapshot by explicit path, basename or timestamp prefix, else newest by mtime
(`_cloudify_runbook_select_snapshot`, `:119-156`), verifies it has a `runbook:`
line (`:856-857`), then seeds from it: `target.<name>` becomes a `--target`
binding unless the CLI already bound that name (`:874-879`, CLI wins
`:859-864`), and each `value.<NAME>` is resolved through the resolver before
being exported, with reserved names refused and a resolution failure fatal
(`:881-892`). The runbook defaults to the snapshot's (`:897-899`), the same
engine runs via `cloudify_deployment_run` (`:924`) with
`CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES` set to the source snapshot (`:923`), and only
value names are printed, never contents (`:906-908`).

Note: the runbook engine does not itself resolve package vars or call package
phases; each step body is a shell command that calls `cloudify`, whose own
walker resolves that child's values. `TARGET_*` and `CLOUDIFY_DEPLOYMENT` are
the coupling between the two.

## 6. Package phases, dependencies, verification, observability gap

### 6.1 Phases and the stable API

Recipe resolution: `cloudify_package_recipe_path` (`lib/packages.sh:123-167`)
tries `<version>.<distro>.<os>.<file>`, `<distro>.<os>.<file>`, `<os>.<file>`,
`<file>` and prefers `install.sh` with `init.sh` as the legacy fallback when
`install.sh` exists (`lib/packages.sh:137-144`). `configure.sh` and
`uninstall.sh` are resolved by explicit filename
(`lib/packages.sh:172-181`), and `verify.sh` is the sibling of the resolved
recipe (`lib/package-api.sh:318-326`).

The plugin API functions defined for recipes are `pkg_backup`
(`lib/package-api.sh:77`), `pkg_restore` (`:131`), `pkg_in_startuprc` (`:173`),
`pkg_apt_update` (`:198`), `pkg_apt_repository` (`:201`), `pkg_apt_install`
(`:204`), `pkg_install_release` (`:207`) and `pkg_depends` (`:397`).
Versions are read from `cloudify_osdetect` (`lib/packages.sh:127-129`).

Install: `cloudify_install_package` (`lib/packages.sh:259-279`) loops the named
packages and calls `pkg_depends "$pkg"` once per package (`:266`); tags are
rejected (`:263-269`).
Configure: `cloudify_configure_package` (`lib/packages.sh:187-217`) sources
`configure.sh` directly in a subshell with `_CLOUDIFY_PKG_DEPTH=1` (`:200`), no
install guard and no FORCE/CLEAR_DATA semantics (`:198`), and dies for a package
without `configure.sh` (`:205`).
Uninstall: `cloudify_uninstall_package` (`lib/packages.sh:290-319`) sources
`uninstall.sh` the same way (`:306`), refuses to guess when there is no
uninstall leg (`:311-313`), and never removes dependencies (`:287-288`).
Split-package sourcing: `_cloudify_source_pkg_phases` sources the install recipe
and then the configure recipe in the same subshell when one resolves
(`lib/package-api.sh:383-394`), so an install-phase `return 0` guard skips the
configure phase (the pattern used by split recipes, e.g.
`pkg/guacamole/install.sh:69-78`).

Force isolation: the router exports `CLOUDIFY_FORCE=true` for explicit installs
locally (`cloudify:263`) and remotely (`cloudify:356`), `--clear-data` also sets
it (`cloudify:422-424`), and it is in the envsubst allow-list so it reaches the
remote (`lib/remote.sh:242`). `pkg_depends` unsets both `CLOUDIFY_FORCE` and
`CLOUDIFY_CLEAR_DATA` before running a dependency recipe
(`lib/package-api.sh:414-418`), so a parent's force flag does not cascade.
`_CLOUDIFY_PKG_DEPTH` defaults to 0 (`lib/package-api.sh:404`); 0 selects the
explicit branch, any positive value selects the dependency branch
(`lib/package-api.sh:413`).

Depth bookkeeping defect: the dependency branch increments as a variable prefix
on `unset` (`_CLOUDIFY_PKG_DEPTH=$((_CLOUDIFY_PKG_DEPTH + 1)) unset CLOUDIFY_FORCE`,
`lib/package-api.sh:416`). Probe 4 shows bash does not persist an assignment
prefix on `unset` in default mode, so the increment is lost; the explicit branch
puts the same prefix on a function call and it does apply
(`lib/package-api.sh:423`). Probe 11 adds the third shape in use: a prefix on
`source` (`lib/packages.sh:200`, `lib/packages.sh:306`) applies for the duration
of the sourced file but not after, so the configure and uninstall phases do see
their constant depth 1. Only the `> 0` test is ever read
(`lib/package-api.sh:413`), so no current behavior changes; the value is
observably wrong only to a future reader.

Native fallback: a name that is not a cloudify package, or a package without a
recipe, falls back to `pkg_apt_install` inside a subshell so a `die` is
contained and the loop continues (`lib/package-api.sh:442-457`).

### 6.2 Dependencies

`pkg_depends` (`lib/package-api.sh:397-472`) loops its arguments, resolves the
recipe, sources the phases in a subshell (`:416` or `:423`), copies
`pkg/<name>/*.script` into `$CLOUDIFY_LOCAL_BIN` (`:429-441`), then runs deep
verify unless disabled (`:459-466`), and finally returns 1 with a
"Failed packages:" summary when any iteration failed (`:468-471`).
Because the phases run inside an `if ! ( ... )` condition, recipe bodies execute
with errexit suspended; that is documented in the errexit artifact and is not
re-derived here.

Which dependencies a dispatch can see for forwarding: `_cloudify_pkg_remote_vars`
recurses with `_recurse_pkg_vars` (`lib/remote.sh:133-150`). It resolves only the
*install-phase* recipe (`lib/remote.sh:141`) and extracts dependency names with
`grep '^[[:space:]]*pkg_depends '` piped to `sed 's/.*pkg_depends //' | tr ' ' '\n'`
(`lib/remote.sh:144-145`). Consequences:
- Only dependencies on a line that begins, after leading whitespace, with
  `pkg_depends ` are found; a call preceded by anything (`&&`, `if`, a variable)
  is invisible. Probe 5 shows the exact pipeline finding `docker a b c`,
  emitting a literal `$PKGS` token for a variable call, emitting a stray `\` for
  a continuation line, and missing the continued `curl`.
- Only the install-phase recipe is walked, so a dependency declared only in
  `configure.sh` would not be forwarded; no package does that today
  (checked across `pkg/*/configure.sh`).
- The walk is depth-first with a `_visited_pkgs` set (`lib/remote.sh:132-136`)
  and rightmost-CLI-package-first (`lib/remote.sh:152-156`), so one shared
  dependency cannot be visited twice and the rightmost package's value wins.
- The runtime dependency graph is whatever the recipe actually calls, which may
  differ from the static graph; nothing reconciles the two.

Which packages a dispatch can observe for state: the registry writer iterates
`_CLOUDIFY_BG_PKGS` (`lib/registry.sh:349`), which the router fills with the
CLI-named package list only (`cloudify:266`, `cloudify:273`, `cloudify:281`,
`cloudify:363`). Dependency recipes installed inside the background child's
`pkg_depends` loop are therefore invisible to the parent and get no record. The
write also requires the pid's `wait` to have returned 0 (`cloudify:778-781`) and
`CLOUDIFY_DEPLOYMENT` to be set (`lib/registry.sh:340-343`); verify actions are
skipped (`lib/registry.sh:336-339`). This is the dependency observability gap.

### 6.3 Verification

`_cloudify_run_verify` (`lib/package-api.sh:335-377`) is the whole verify path.
- No `verify.sh` = success, additive hook (`lib/package-api.sh:339`).
- The package yaml is loaded into the current process through the flat reader
  with a temporary ledger in `no-clobber` mode (`:345-349`), so a value already
  forwarded by the walker is not overwritten.
- Each attempt sources `verify.sh` and calls `pkg_verify` in a clean subshell
  with all output captured: `if last_err=$( { source "$verify_path" && pkg_verify; } 2>&1 )`
  (`:361`). Verify output therefore does not stream; it is printed only on the
  final failure (`:374-375`).
- The retry loop runs until `${PKG_VERIFY_TIMEOUT:-30}` seconds elapse, sleeping
  2s per attempt and logging a heartbeat every tenth attempt (`:351-372`).
- Deep verify runs after every package inside `pkg_depends`, including
  dependencies, and is gated by `CLOUDIFY_NO_VERIFY` (`:459-466`);
  `cloudify_configure_package` runs the same hook after configure
  (`lib/packages.sh:208-210`). There is no separate shallow-verify path:
  `verify.sh` is either sourced and called, or skipped by `CLOUDIFY_NO_VERIFY`;
  "deep" means the hook also runs for every dependency pulled by `pkg_depends`.

Verify-only paths: `cloudify verify <pkg>` and `cloudify --verify install <pkg>`
set `CLOUDIFY_VERIFY_ONLY` (`cloudify:657-658`) and are routed by
`_cloudify_dispatch`'s verify branch (`cloudify:321-338`). Local verify runs
`_cloudify_run_verify` per package in a background subshell
(`cloudify:285-296`) without invoking the value walker. Remote verify calls
`cloudify_remote "$host" "verify <pkgs>"` (`cloudify:334`), and
`_cloudify_pkg_remote_vars` treats a non-install command as "global only"
(`lib/remote.sh:110-113`, `:179-182`), so only global vars are forwarded on a
remote verify. The asymmetry is current behavior, not a claim about intent.

## 7. Current persistence surfaces: registry and deployments

### 7.1 Registry (`lib/registry.sh`)

Purpose and the observation-only rule are stated at `lib/registry.sh:2-21` and
`ADR.md` ADR-020 point 1. One record per (deployment, target, package)
(`lib/registry.sh:4-5`).

Bucket resolution: an ivps node dir via `ivps node path` (`lib/registry.sh:36-43`),
instance appended when the target is an instance (`lib/registry.sh:64-66`), else
a fallback bucket `${CLOUDIFY_CREDENTIALS_DIR}/registry/hosts/<ssh_host>`
(`lib/registry.sh:31-33`, `:69-72`); an unaddressable target yields rc 1 and the
caller warns rather than fails (`lib/registry.sh:87-88`, `:351-353`).
Path validation rejects `/`, `.` and `..` in every component
(`lib/registry.sh:48-57`). The record path is
`<bucket>/deployments/<id>/pkgs/<pkg>/config.yaml` (`lib/registry.sh:89`).

Writes: `cloudify_registry_put` creates the parent chain with `umask 077`, pins
0700/0600, and writes via `mktemp` in the record's own dir plus `mv`
(`lib/registry.sh:94-110`), so writes are atomic and a concurrent write to the
same slice is last-writer-wins (accepted, `lib/registry.sh:18-19`).

Schema and the independent raw-value walk: the record is a flat `key: value`
file with a leading comment, fixed field order, and `var.<NAME>` fields
(`lib/registry.sh:205-217`, `:296-317`). The writer merges the existing record
to carry `installed_at`/`configured_at`/`removed_at`/`version` forward
(`lib/registry.sh:277-305`), and status is derived from the action
(`install` -> `installed`, `configure` -> `configured`,
`uninstall` -> `removed`, `:289-294`), so uninstall is a timestamp, never a
delete (`lib/registry.sh:209-210`).

The raw-value walk is `_cloudify_registry_raw_var`
(`lib/registry.sh:249-267`): `caller env > deployment > package > global`, in
that order, returning the first raw value. It never resolves references
(the comment at `:249-251`; probe 6 shows `@base64:aGVsbG8=` stored verbatim),
it stores multiline values as `@base64:` (`:313-315`), and it enumerates names
from `.remote-vars` in declaration order (`_cloudify_registry_declared_names`,
`:230-247`). This is the second value walk that ADR-021/ADR-022 identify as the
defect to remove; note that it is a *different implementation* from the
forwarding walker (env-first vs ladder-with-ledger) and can disagree with it.

The registry is never a ladder source: `lib/vars.sh` has no registry reference,
`cloudify_vars_state_read` is a stub (`lib/vars.sh:504-506`), and the only
caller of a registry reader is the registry writer itself
(`lib/registry.sh:277`). ADR-020 point 1 states this as a decision; the code
enforces it by omission. Probe 6 proves the raw reader's order and non-resolution.

Sweep: `cloudify_deployment_delete` (`lib/deployments.sh:64-85`) trashes the
deployment dir and then calls `cloudify_registry_delete_deployment`
(`lib/deployments.sh:78-83`), which globs candidate roots from the ivps nodes
dir and the fallback root and removes only directories that contain a `pkgs/`
subdir (`lib/registry.sh:162-203`). A record dir already emptied by
`cloudify_registry_delete` is intentionally left in place
(`lib/registry.sh:183-185`).

### 7.2 Deployment inputs (`lib/deployments.sh`)

The store root is `${CLOUDIFY_CREDENTIALS_DIR}/deployments`
(`lib/deployments.sh:14`). Each deployment is one directory plus one flat
`config.yaml` (`lib/deployments.sh:27-29`); ids reject `/`, `.` and `..`
(`lib/deployments.sh:19-24`); create is idempotent and pins 0700/0600
(`lib/deployments.sh:31-61`). Var reads/writes go through `lib/vars.sh`
(`lib/vars.sh:259-310`, `:395-410`), and the store file is exactly what the
deployment var writer writes (`lib/vars.sh:281-287`). `deployment delete` is
destructive: it `trash-put`s the directory with an `rm -rf` fallback
(`lib/deployments.sh:68-73`). This is the "single-ID desired-input store" that
v2 Phase 3 moves to a nested application/flavor/name path.

Run snapshots also live under the deployment store,
`<deployments>/<id>/runs/<UTC>.yaml` (`lib/runbooks.sh:772-789`), which is the
third current write surface.

## 8. Load-bearing invariants

Each is a positive invariant with the code that enforces it. This list is the
input to G2; no change is proposed here.

1. All value resolution exports into the current shell; collectors are invoked
   with a redirect, never captured with `$(...)`. `lib/vars.sh:5-8`,
   `lib/vars.sh:96-118`; call sites `cloudify:251`, `:263`, `:270`, `:278`;
   `lib/remote.sh:91-92`, `:216-220`.
2. The remote payload travels on stdin and the SSH command is `bash -s`;
   no value is ever in ssh argv. `lib/remote.sh:269-274`; probe 7.
3. stdin is redirected per command and there is no global `exec </dev/null` in
   the payload; the only global redirect is stdout/stderr to the tee.
   `lib/remote.sh:74-77`, `:60`, `:73`, `:246`; probe 1;
   `tests/unit/remote-stdin.bats:41-47`.
4. Precedence is first-claim-wins over a fixed visit order, with caller env
   preserved and never overwritten. `lib/vars.sh:51-59`, `:96-118`;
   `lib/remote.sh:126-178`; probe 3.
5. A name is forwarded only when a `.remote-vars` declaration or a file store
   knows it; an ambient env var is never forwarded. `lib/vars.sh:223-248`,
   `:314-326`; `lib/remote.sh:161-178`; probe 3G.
6. File-store values have their `@backend:` references resolved; caller-env
   values pass through verbatim. `lib/vars.sh:110-113` vs `:243`, `:322`;
   probe 7; `lib/runbooks.sh:887-891`.
7. An unresolvable or malformed secret reference fails the run and no empty
   value is forwarded. `lib/vars.sh:74-94`, `:110-112`; `lib/secrets.sh:31-44`;
   probe 8.
8. Framework-owned names cannot be set by a file store.
   `lib/vars.sh:28-49`, `:98-101`; probe 8.
9. The remote payload is the literal text of the template function body, minus
   the two `declare -f` structural lines at the head and the closing brace.
   `lib/remote.sh:234`; probe 1.
10. Only allow-listed names are substituted; substitution is single-pass with no
    rescan of inserted text, and matching is by full name rather than prefix.
    `lib/remote.sh:241-243`; probe 2a, 2b, 2c.
11. A claimed name that also occurs as template text is substituted everywhere
    in the payload, and `HOME`/`PATH`/`USER` are not reserved.
    `lib/remote.sh:241-243`, `lib/vars.sh:28-39`; probe 2e.
12. Substituted values are baked inside single quotes, so spaces, `$` and
    `$( )` stay literal on the remote; a single quote in a value escapes the
    quotes and the rest of the line executes. `lib/remote.sh:228`, `:237`;
    `lib/remote.sh:18`; probe 2d, 2d2; `pkg/guacamole/install.sh:45-48`.
13. Secret values reach the remote only through the stdin payload; debug
    masking is a name heuristic, not a whitelist. `lib/remote.sh:248-259`;
    probe 7.
14. Dispatch exit status comes from `wait` on the background pid, and the
    registry record is written by the parent only for a pid that returned 0.
    `cloudify:778-786`; `lib/remote.sh:188-192`.
15. `$CLOUDIFY_TMP/<host>.exit` is a write-only diagnostic in the current code.
    `lib/remote.sh:206`, `:280`; `cloudify:327`, `:341`; no reader in `lib/` or
    the router.
16. The registry is observation only and is never consulted by the value ladder.
    `lib/registry.sh:2-7`, `lib/vars.sh:504-506`; ADR-020 point 1.
17. Registry writes are atomic and permissioned, and a record merges previous
    timestamps instead of deleting them. `lib/registry.sh:94-110`, `:272-305`.
18. Registry `var.<NAME>` values are raw, unresolved, and first-providing-source
    only. `lib/registry.sh:249-267`, `:312-316`; probe 6.
19. `deployment delete` sweeps every registry record dir for that deployment,
    and only directories containing a `pkgs/` subdir are removed.
    `lib/deployments.sh:78-83`; `lib/registry.sh:162-203`.
20. Deployment inputs are one flat `config.yaml` per id, 0700/0600, and delete
    is destructive. `lib/deployments.sh:14-85`; `lib/vars.sh:281-287`.
21. Runbook steps are typed fenced blocks, validated against declared targets,
    with required `pkg=` for package types and unique ids.
    `lib/runbooks.sh:240-274`.
22. Runbook target binding prefers the CLI over `TARGET_<NAME>` and fails closed
    on an unbound or undeclared target. `lib/runbooks.sh:363-422`.
23. Runbook preflight checks required declarations through the same source
    function used for display, with `CLOUDIFY_DEPLOYMENT` exported.
    `lib/runbooks.sh:429-478`, `:440-442`.
24. Runbook steps run in a child `bash -c` with `/dev/null` stdin; the step list
    is pre-read so a body cannot consume it; the first failure stops the run and
    a snapshot is always written, 0600 and atomic. `lib/runbooks.sh:700-704`,
    `:744-748`, `:766`, `:771-789`.
25. Step outputs flow through a 0600 file read by line offset, and each becomes
    `OUT_<name>` for later steps. `lib/runbooks.sh:657-660`, `:751-764`.
26. Replay seeds target bindings and resolved `value.*` values from a snapshot,
    refuses framework-owned names, and reuses the same engine.
    `lib/runbooks.sh:866-892`, `:923-924`.
27. `pkg_depends` runs dependency recipes with `CLOUDIFY_FORCE` and
    `CLOUDIFY_CLEAR_DATA` unset, so a parent force does not cascade.
    `lib/package-api.sh:404`, `:413-427`.
28. The dependency-branch depth increment is lost because it is a prefix on
    `unset`, and no code reads the value beyond the `> 0` branch test.
    `lib/package-api.sh:416`, `:413`; probe 4. A prefix on `source`
    (`lib/packages.sh:200`, `:306`) applies during the sourced file; probe 11.
29. Forwarded dependency names come from a line-oriented grep of the resolved
    install-phase recipe only. `lib/remote.sh:140-150`; probe 5.
30. The registry observes only CLI-named packages; dependency installs are
    invisible to the parent. `lib/registry.sh:349`; `cloudify:266`, `:363`;
    `lib/package-api.sh:405-427`.
31. Deep verify runs after every package including dependencies and is skipped
    by `CLOUDIFY_NO_VERIFY`. `lib/package-api.sh:459-466`; `cloudify:654-655`.
32. Verify sources `verify.sh` and `pkg_verify` in a clean subshell with output
    captured; the optional hook is a no-op when absent.
    `lib/package-api.sh:335-377`.
33. `cloudify verify` and `--verify install` bypass install; local verify skips
    the value walker and remote verify forwards global vars only.
    `cloudify:321-338`, `:283-296`; `lib/remote.sh:110-113`, `:179-182`.
34. The shadows intercept bare `sudo`, `apt-get`/`apt`, `add-apt-repository` and
    `git`, must be non-interactive and idempotent, and can return a status that
    belongs to a later step (exit-code swallowing).
    `lib/shadow.sh:11-14`; `lib/shadows/apt-get.sh:16-19`, `:51-63`;
    `lib/shadows/add-apt-repository.sh:9-30`; `lib/shadows/sudo.sh:16-18`,
    `:75-85`, `:98-110`; `lib/shadows/git.sh:113-121`; probes 9 and 10.

## 9. Probes

All probes live in `~/tmp/state-model-v2-probes/`; run each with
`bash ~/tmp/state-model-v2-probes/<script>`. Outputs are trimmed to the line
that proves the claim.

- `p1-payload-template-extraction.sh` - proves the `declare -f` extraction
  shape. Command: `bash p1-payload-template-extraction.sh`.
  Observed: raw `declare -f` is 48 lines, first two are
  `cloudify_remote_payload_template () ` and `{ `, last is `}`; the extracted
  payload is 45 lines, first `    export CLOUDIFY_IS_LOCAL=false;`, last `    :`,
  and the placeholder appears once as `    : _CLOUDIFY_PKG_EXPORTS_;`.
- `p2-envsubst-allowlist.sh` - proves envsubst semantics (sections 3.4).
  Observed: (a)`a=$HOME b=$(date) c=tok d=$CLOUDIFY_FORCE` with allow-list
  `$K3S_TOKEN` leaves `$HOME`, `$(date)` and `$CLOUDIFY_FORCE` literal;
  (b) allow-list `$K3S` leaves `$K3S_TOKEN` unsubstituted and substitutes only
  `$K3S`; (c) a value containing `$CLOUDIFY_FORCE` is not re-expanded even when
  that name is in the format; (d) `X="a'; echo pwned-marker; echo '"` renders
  `export X='a'; echo pwned-marker; echo ''` and prints `pwned-marker`;
  (d2) `X='a b $(id)'` evaluates to the single literal `a b $(id)`;
  (e) with `$HOME` allow-listed, `export CLOUDIFY_LOCAL_BIN="$HOME/.local/bin"`
  becomes `="/evil/.local/bin"`.
- `p3-ledger-precedence.sh` - proves the ladder and the name gate.
  Observed, with all four stores present: env value wins (A), env unset ->
  deployment (B), deployment store absent -> package (C), package yaml absent ->
  global (D), an env-only declared name is forwarded (E), an undeclared ambient
  name is not claimed (G lists `GLOBALONLY`, `ONLY_ENV`, `SHARED` only).
- `p4-depth-prefix.sh` - proves the dependency-branch depth increment is lost.
  Observed: `D=0; ( D=$((D+1)) unset FOO; echo $D )` prints 0; the same prefix
  on a function call prints 1.
- `p5-dep-walk.sh` - proves the static dependency walk's shape and blind spots.
  Observed: the pipeline over a fixture recipe emits `docker a b c $PKGS git \`,
  i.e. it tokenizes only line-start `pkg_depends` calls and treats
  variable/continuation forms as literal names; the repo-wide check found no
  such forms in `pkg/*/*.sh` today.
- `p6-registry-raw.sh` - proves the registry raw walk and its order. Observed:
  a deployment-store `@base64:aGVsbG8=` is returned verbatim (not decoded), env
  wins over every store, a global-only name resolves, an unknown name returns
  rc 1, and declared-name enumeration is in declaration order.
- `p7-guacamole-payload.sh` - captures the real payload for `guacamole` with a
  stubbed `ssh` (full text in 3.5). Observed: ssh argv is
  `... testuser@somehost bash -s` with no value; the export block contains the
  four claimed names; the caller-env `@base64:` secret is forwarded undecoded;
  no undeclared recipe var (`CLOUDIFY_GUACAMOLE_VERSION`) is forwarded.
- `p8-secret-resolver.sh` - proves the resolver's source forms. Observed: plain
  identity, `@@literal` -> `@literal`, base64 round-trip including a newline,
  and rc 1 for `@`, `@nosuch:loc`, `@nocolon`, `@:loc`, `@back:`; a caller-env
  name is preserved by `_cloudify_vars_emit`; a name already in the ledger is
  not overwritten; a reserved name from a file store is skipped with a warning.
- `p9-apt-swallow.sh` - proves the apt shadow's per-package swallow with stubbed
  `sudo`/`dpkg`. Observed: `apt-get install -y b a` returns 0 although `b`
  failed; `apt-get install -y a b` returns 100 because `b` was last.
- `p10-git-swallow.sh` - proves the git shadow masks a failing clone with a fake
  `git` on PATH and a throwaway HOME. Observed: a clone exiting 3 returns 0 with
  credentials and also with none; a non-clone without credentials passes the
  real rc 4 through.
- `p11-source-prefix.sh` - proves where an assignment prefix applies.
  Observed: `D=1 source f` shows `D=1` inside the sourced file and `D=0` after;
  `D=1 unset X` leaves `D=0` after (`unset` has no body, so the increment is
  lost); `D=1 f` shows `D=1` inside the function; `D=1 echo` shows `D=0` inside
  a regular builtin.

## 10. Uncertainties

1. No live remote dispatch was executed (it would mutate hosts). The remote half
   of the chain is proven by the stubbed-ssh payload capture (probe 7) plus
   code reading; the actual remote execution of the payload, the gist bootstrap,
   and the remote `cloudify` re-walk were not observed in this phase.
2. The gist body is not part of the repository. Section 3.4 quotes the
   commit-pinned raw URL set at `cloudify:72`, fetched read-only during this
   phase; if that gist revision is edited (the URL pins a revision, so it should
   not be), the quoted bootstrap content would drift without any repo change.
3. `envsubst` behavior (no prefix match, no rescan, unlisted names untouched)
   is proven on GNU gettext-runtime 0.21 on this host. The payload uses no
   envsubst version check, so an older or non-GNU `envsubst` could differ; not
   proven for other versions.
4. `declare -f` formatting (two structural lines then body then `}`) is proven
   for bash 5.1.16 only. A bash build that emits a different function header
   would shift the extraction; not tested across versions.
5. The dependency-branch depth loss is proven in default bash mode; no
   `set -o posix` or `POSIXLY_CORRECT` appears anywhere in `lib/`, the router,
   `pkg/` or `tests/`, so the default mode is what runs. Semantics would flip
   under POSIX mode; not tested. Probe 11 additionally shows the `source` prefix
   applies for the sourced file's duration; that ordering is bash 5.1.16
   behavior.
6. Registry bucket behavior for the `local` node depends on `ivps node path
   local`. No ivps call was made in this phase, so the fallback-vs-node-dir
   outcome for `localhost` is inferred from `lib/registry.sh:12-14` and
   `:62-73`, not observed.
7. Last-writer-wins for concurrent registry writes to the same slice is stated
   in the code comment (`lib/registry.sh:18-19`) and accepted by design; no
   concurrency probe was run.
8. Whether `$CLOUDIFY_TMP/<host>.exit` is consumed by anything outside this
   repository (operator scripts, older revisions) is unknown; in-repo it has no
   reader.
9. The claim that no package declares a dependency only in `configure.sh` and
   that no `pkg_depends` call uses a variable or continuation was checked with
   text greps over `pkg/*/*.sh` at this commit (probe 5) and is only as strong
   as those greps; a recipe generated at runtime or a line split inside a
   subshell would evade them.
10. The runbook engine and the registry were read and unit-tested patterns were
    inspected, but neither was executed here; the claims about their behavior
    rest on code plus their existing bats suites
    (`tests/unit/runbooks.bats`, `tests/unit/runbook-exec.bats`,
    `tests/unit/registry*.bats`), which were not run in this read-only phase.
