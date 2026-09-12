# State model v2 - G2 non-breakage argument

Second artifact of the CRITICAL GATE, written after G1 was accepted. G1 is
`plans/state-model-v2-description.md`; every invariant number cited below as
`inv N` refers to its section 8. G2 argues that each planned phase preserves the
mechanisms G1 described. It approves nothing: G3 is Rachid's explicit consent,
and the scope enumerated in section 7 is exactly what consent would cover.

## 1. Method

Each phase is checked against the 34 G1 invariants, not against intent.
"Byte-identical" below means the file's contents or the function's emitted text
does not change, and the check is a diff or a golden-text test, not a reading.
Where a phase cannot preserve an invariant, section 6 says so and names the
change that needs separate consent.

## 2. Touch matrix, per phase

The seven brittle families are `lib/remote.sh`, the `cloudify` router,
`lib/shadows/*.sh`, the package API (`lib/package-api.sh`, `lib/packages.sh`),
the runbook engine (`lib/runbooks.sh`), registry/deployment storage
(`lib/registry.sh`, `lib/deployments.sh`, `lib/vars.sh` stores), and ivps.

- Phase 1: remote.sh no; router no; shadows no; package API no; runbooks no; storage no; ivps no. Tests, fixtures, plans and docs only.
- Phase 2: remote.sh yes (payload build, walker call site); router yes (dispatch wiring, context lifecycle); shadows no; package API no (verify reads the yaml itself, see 6.1); runbooks yes (snapshot source-form, preflight); storage yes (`lib/vars.sh` resolver plus the registry writer's input); ivps no.
- Phase 3: remote.sh no; router yes (`app` commands, `CLOUDIFY_*` exports); shadows no; package API no; runbooks yes (tree, phases, preflight); storage yes (nested input path, manifest, read-through); ivps no.
- Phase 4: remote.sh no; router yes (lock acquire around dispatch, result channel); shadows no; package API yes (claims, result reporting, install guards); runbooks yes only for the teardown-phase step ids Phase 7 pins; storage yes (package state, locks); ivps no.
- Phase 5: remote.sh yes (ssh options, debug rendering); router yes (secret metadata plumbing); shadows no; package API yes (digest resupply before verify/teardown); runbooks yes (stop writing `output.*`); storage yes (secret metadata, digests); ivps no.
- Phase 6: remote.sh no; router yes (run lifecycle wiring); shadows no; package API yes (result commits); runbooks yes (run records, no values); storage yes (events, run records, locks); ivps no.
- Phase 7: remote.sh no; router yes (upgrade and migration verbs); shadows no; package API yes (claim release paths); runbooks yes (pinned-commit resolution); storage yes (manifest, desired inputs); ivps no.
- Phase 8: remote.sh no; router yes (read commands, legacy delete guard); shadows no; package API no; runbooks yes (legacy delete refusal only); storage yes (migration reader/writer); ivps no (the external-host migration moves Cloudify-owned files, 8.3).
- Phase 9: docs and skills only; no family touched.

No phase writes to the ivps repository or its inventory. `lib/targets.sh` keeps
reading `ivps node path` and `ivps list` only. The deferred ivps items stay out.

## 3. The six required proofs

### 3.0 Invariants per phase

- Phase 1: no invariant is at risk; no family is touched.
- Phase 2: inv 1, 4, 5, 6, 9, 10, 11, 12, 13, 16, 18, 23, 29, 32, 33. The risk is the value channel (3.1), the payload text (3.2 to 3.4) and the removal of the second walk (6.1).
- Phase 3: inv 20, 21, 22, 23, 24, 26. The risk is legacy runbook and deployment readability (section 5).
- Phase 4: inv 27, 28, 29, 30, 31, 34. The risk is the direct-command behavior set (3.5, 7.2) and the missing result channel (6.2).
- Phase 5: inv 2, 12, 13, 24, 25. The risk is the ssh option change (section 4) and removing persisted outputs (section 5).
- Phase 6: inv 14, 17, 24. The risk is writer ordering and lock scope; all writes are additive.
- Phase 7: inv 19, 26. The risk is teardown reach; claims, not code paths, decide what is removed (3.5, 7.2 item 1).
- Phase 8: inv 16, 19, 20. The risk is migration touching old files; it does not (section 5).
- Phase 9: no invariant is at risk; docs and skills only.

### 3.1 Collector exports remain the value channel and are never captured with `$()`

Today the walker is invoked with a file redirect (`_cloudify_pkg_remote_vars
"$@" > "$_pkg_vars_list"`, inv 1) precisely because it exports into the caller's
shell; `$(...)` would run it in a subshell and lose every export.
Rule for every phase that touches value resolution: the resolver exports into
the current shell and the caller redirects its stdout to a file; no call site
may use `$(...)` or a pipeline. The existing call sites
(`cloudify:251/:263/:270/:278`, `lib/remote.sh:216`) are the test surface: each
must still see the resolved names in its own environment.
Phase 2 changes the walker's internals, not its channel, so this is preserved by
construction and proven by a test that runs a dispatch and asserts the exported
names are visible in the same shell that called the resolver.
Verification is an exception, not a violation: `_cloudify_run_verify` sources
the package yaml with its own ledger (inv 32), and no phase may replace that
with command substitution.

### 3.2 Payloads stay on stdin and secrets never enter argv

Inv 2 and inv 13 hold if the transport statement itself does not change:
`ssh -o ... "$CLOUDIFY_REMOTE_USER@$host" 'bash -s' < "$payload_file"` with a
0600 mktemp file, and the appended `; cloudify $* </dev/null`.
Phase 2 adds a context file, and the one way to break this is to pass that path
as an argument: the appended remote command is built from `$*`, so any new token
added to the remote command line lands in ssh argv, which is visible in the
process list. Phase 2.2's rule "context paths and values never enter the remote
command argv" is therefore a hard constraint, and the check is that the argv
string equals the payload's last line and contains nothing but the action and
package words.
Secrets reach the remote only through the payload body, so a second constraint
follows: the context file is read locally and its values are rendered into the
payload, never referenced by path from the remote side.
Payload-text tests assert that `ssh` arguments contain no value and that the
payload contains the literal.

### 3.3 The `envsubst` allow-list contains exactly the resolved dispatch names

The allow-list is one string: 25 fixed framework tokens followed by
`${pkg_envsubst}` with one ` $NAME` per claimed name (inv 10).
Phase 2.3 keeps both halves and only changes where the name list comes from, so
the list stays "exactly the resolved dispatch names plus the fixed framework
tokens" if and only if the resolver emits exactly the names it exports.
Check: for one dispatch, the set in the `envsubst` format equals the sorted set
of names the resolver claimed, and no other name in the payload is substituted
except the 25 fixed tokens. A golden-payload test with a known fixture package
pins this.
Substitution semantics are unchanged because the mechanism does not change:
single pass, full-name matching, no rescan of inserted text (inv 10, probes 2a
to 2c). The name-collision hazard (inv 11: a claimed name that also appears as
template text, for example `HOME`) is a pre-existing behavior, not something
Phase 2 introduces, and a fix means widening `_CLOUDIFY_VARS_RESERVED`, which
changes payload substitution for real dispatches. That fix is listed in 6.4 as a
separate consented change and is not bundled.

### 3.4 Remote-side single-quoted exports preserve literal expansion timing

Each claimed name is rendered as `export <NAME>='$<NAME>'` and envsubst fills
the inner reference, so the remote shell receives a single-quoted literal
(inv 12). Spaces, `$`, backticks and `$( )` therefore stay data at the moment
the remote process starts, and only the remote shell's own later expansion can
change them.
Preserved if and only if Phase 2.3 keeps the quote form and the same rendering
function. Check: a payload-text test with values containing a space, `$HOME`,
`$(id)` and a backtick asserts the exact `export NAME='...'` line, and an L1
driver on the container asserts the recipe reads the literal back.
The known single-quote landmine stays as it is: a value containing a single
quote closes the quote and the rest of the line executes. The declaration file
warns about it (`pkg/guacamole/.remote-vars:3`, inv 12). Any encoding change
(for example base64 in the payload with a remote decode) alters the payload
format for every dispatch and is listed in 6.5 as a separate consented change.

### 3.5 Direct package commands keep their signatures; claim protection is the one approved safety change

Signatures that must not change: `cloudify_install_package <pkgs...>`,
`cloudify_configure_package <pkgs...>`, `cloudify_uninstall_package <pkgs...>`,
`pkg_depends <pkgs...>`, `_cloudify_run_verify <pkg>`, and every recipe-facing
`pkg_*` function (Phase 4.7 states the same requirement).
Phase 2 preserves behavior entirely: the same stores, the same precedence, the
same `CLOUDIFY_FORCE` handling, the same failure text shapes.
The behavior changes inside those signatures are confined to Phase 4 and are the
enumerated scope in 7.2: a claim guard before uninstall reaches recipe code, a
no-op plus verify when installing over an existing claim, a fail-with-directions
when explicit inputs differ from applied state, and applied-state resolution for
reconfigure, verify and teardown. Each of those is a deliberate safety change
that needs consent; nothing else in the direct paths moves.
One consequence to state plainly: after Phase 4, `cloudify uninstall <pkg>` on a
host where another deployment holds a claim no longer removes the package. That
is a user-visible behavior change by design, and it is the change most likely to
surprise an operator.

### 3.6 Shadow lookup and behavior stay byte-identical

No phase in the plan modifies `lib/shadows/*.sh` or `lib/shadow.sh` (section 2,
seven families, all "shadows no"). The four functions, their lookup (each file
defines a function named after the real command), their `command <name>`
escape, and their exit-code swallowing (inv 34, probes 9 and 10) are therefore
unchanged.
Check: `git diff --stat` over `lib/shadow.sh` and `lib/shadows/` must be empty at
every phase boundary, backed by a sha256 pin of the five files asserted in the
test suite so an accidental edit fails loudly instead of passing silently.
The one indirect dependency to watch: recipes call bare `sudo`, `apt-get`,
`add-apt-repository` and `git`, so any change to recipe execution context
(cwd, stdin, environment) can change shadow behavior without touching the files.
Phase 4.7's "dependency result reporting must not consume recipe stdin or
stdout" is the concrete guard, and Phase 6's locks must not be acquired inside a
recipe subshell in a way that changes stdin.

## 4. SSH host-key pinning: the explicit `remote.sh` change

Pinning is a Phase 5 item and the highest-blast-radius non-state change in the
plan, so its transport argument is stated here before any consent.

What changes: the two `ssh` options
`-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no` are replaced by a
policy over a Cloudify-owned known-hosts file. Everything else on the command
line stays: the same `"$CLOUDIFY_REMOTE_USER@$host"` argument, the same
`ConnectTimeout=10`, the same `'bash -s' < "$payload_file"` stdin transport, the
same backgrounding, the same teeing and exit-code capture.

Invariants preserved: payload transport (inv 2) is untouched because it lives in
the redirect and `bash -s`, not in the options; credentials
(`CLOUDIFY_REMOTE_USER`, `CLOUDIFY_REMOTE_PWD`) flow through the gist and the
payload, not through ssh options; local dispatch never calls `ssh` at all
(`lib/remote.sh` localhost branch), so localhost is unaffected; node, instance
and external hosts all resolve to one `ssh_host` string before this call, so the
change is connection policy, not target-kind logic, and cannot change target
resolution.

What breaks if it lands naively: today host-key checking is disabled, so remote
installs work against any host. Fail-closed pinning turns an unknown key into a
failed install for every operator who has no recorded key, and a stale pin
breaks an install that used to succeed after a host rebuild; that is a real
behavior break, not a hardening detail.
Required handling: record on first connection with an explicit warning, verify
thereafter, fail closed on mismatch, and ship the rotation command in the same
slice. The change must land as its own slice with its own L1 and L2 remote
install on the container, never as a batch with other Phase 5 work. If Rachid
prefers, the default can stay legacy for one release while pinning is opt-in,
which keeps the invariant and defers the break.

## 5. Old state stays readable before any writer switches format

Ordering rule for every phase: a new reader ships before any writer that could
make an existing file unreadable, and no phase mutates an old file in place.
- Phase 2: the registry record keeps the same flat `var.<NAME>` schema and the
  same path, so the old reader and the new reader agree during the switch; the
  compatibility period keeps both (Phase 2 rollback items).
- Phase 3: nested inputs are additive; the single-ID store stays and is read
  through. Nothing moves until migration confirmation, and the old code ignores
  the new directory.
- Phase 4: package state is new state under the Cloudify state root, seeded from
  existing successful registry observations. Migration is a read of the old
  records plus a write elsewhere, so reverting the code leaves the old records
  intact and authoritative.
- Phase 5: new run records stop carrying `output.*`; old snapshots keep theirs
  and the reader tolerates the absence: the replay path needs a `runbook:` line
  (`lib/runbooks.sh:856-857`) and the selector only needs the file to exist, so
  a snapshot without `output.*` stays usable. Deployments with no Cloudify state
  root continue to resolve against the old registry.
- Phase 6: events and run records are additive; the legacy registry path stays
  written during compatibility (Phase 6 non-breakage, "events are additive and
  snapshots remain available").
- Phase 8: migration is dry-run first, idempotent, and never deletes the old
  paths; old writers are removed before old readers, and old readers only in a
  later release with explicit consent.

## 6. Residual risks that G2 cannot close

These are honest gaps, not arguments.

### 6.1 The verify path reads values itself

`_cloudify_run_verify` loads the package yaml with its own ledger in no-clobber
mode (inv 32), which is a second value entry point beside the walker. If Phase 2
feeds verify from the dispatch context, verify behavior changes (source forms,
resolution timing, and which names are known), and that is a behavior change
needing tests and a place in the consent scope. Recommendation: leave verify's
own load in place during Phase 2 and change it only with the Phase 4
applied-state work, where it is part of the enumerated scope.

### 6.2 The remote result channel has no existing implementation

Today the only remote-to-parent signals are stdout (tee'd to the log) and the
write-only `$CLOUDIFY_TMP/<host>.exit` (inv 15). Phase 4.7 needs a structured
channel listing every package `pkg_depends` actually attempted. Parsing stdout
is unsafe because recipes print freely and cannot be told to stop (inv 34's
context and the package API's stability rule). The realistic options are a
sentinel-framed tail on stdout or a second ssh read of a remote file; both are
new transport, and the chosen one needs its own non-breakage note and consent
before Phase 4 is implemented. This is the strongest implementation risk in the
plan.

### 6.3 Facts proven about this host, not about every host

The `declare -f` extraction shape is proven on bash 5.1.16 and `envsubst`
semantics on gettext-runtime 0.21 (G1 uncertainties 3 and 4). A different remote
bash or envsubst could shift the extraction or the substitution. Mitigation: the
first approved slice runs an L2 remote install on the container, and the payload
tests assert the extraction shape as text.

### 6.4 Pre-existing, unrelated to v2, and still open

- The allow-list name-collision hazard (inv 11): a declared name like `HOME`
  rewrites bootstrap lines. A fix changes `_CLOUDIFY_VARS_RESERVED` and therefore
  payload substitution for real dispatches; separate consent.
- The single-quote injection in baked exports (inv 12): a fix changes the
  payload value encoding for every dispatch; separate consent.
- The swallowed dependency-branch depth increment (inv 28): proven behaviorally
  inert today because only the `> 0` test is read; Phase 2 must not "fix" it
  silently while rewriting the branch.
- The `pkg_depends` static-walk blind spots (inv 29): variable and continuation
  calls are invisible to forwarding. Phase 2 expands the graph, which changes
  which names are forwarded for such recipes. Today no recipe uses those forms
  (probe 5), so the change is inert; if one appears, expansion is the intended
  fix and belongs to the Phase 2 tests.

## 7. Scope that consent would cover

### 7.1 Rollback boundaries, per phase

- Phase 1: revert the commit. Nothing written outside `tests/`, `plans/`, docs.
- Phase 2: revert `lib/vars.sh`, `lib/remote.sh`, `lib/registry.sh`, `lib/runbooks.sh`, `cloudify` to the pre-phase revision; the registry schema and paths are unchanged, so no data restoration is needed.
- Phase 3: revert the same style of code; the runbook tree changes are repo files restored by the revert; manifests and nested inputs are additive directories the old code ignores; the single-ID store is untouched.
- Phase 4: revert `lib/package-api.sh`, `lib/packages.sh`, router wiring; delete the Cloudify state-root package state directory (it is derived from registry observations, so nothing unique is lost); lock files are inert.
- Phase 5: revert `lib/remote.sh` (ssh options and debug rendering), `lib/vars.sh`, `lib/registry.sh`, `lib/runbooks.sh`; snapshots already written keep their `output.*`; recorded host keys are inert data, and reverting the option restores today's transport.
- Phase 6: revert the event and run writers and router wiring; events stay on disk as orphaned evidence; package state remains readable by the Phase 4 code.
- Phase 7: revert the pinned-commit resolution, the teardown-claim paths and the new verbs; the manifest's commit field is inert data.
- Phase 8: revert the read commands and the migration tool; migration wrote only to new paths and never deleted old ones, so the pre-Phase-8 code still reads everything.
- Phase 9: docs and skills revert by commit.

The single non-revertable item is data written by a phase that a later phase's
files already consumed; the ordering rule in section 5 is what keeps each phase
revertable, and Phase 8.4 states the reverse-transformation refusal explicitly.

### 7.2 The one approved behavior change set

Everything else in the plan is either additive, internal, or unchanged. Consent
should name exactly these:
1. Uninstall refuses to remove a package while another deployment holds a claim (Phase 4.6).
2. Install over an existing compatible claim becomes a no-op followed by verification (Phase 4.4).
3. Install whose explicit inputs differ from applied state fails and directs the operator to reconfigure or upgrade (Phase 4.4).
4. Reconfigure, verify and teardown resolve from applied state with deployment inputs and defaults in the documented order (Phase 4.4).
5. New runs stop persisting step outputs; `output.*` in old snapshots stays readable (Phase 5.3).
6. Rendered payloads leave debug output, replaced by names, sources and redaction status (Phase 5.4).
7. SSH host-key policy changes from disabled to recorded-verify-fail-closed (Phase 5.4, with section 4's handling and either opt-in or an accepted break).
8. Legacy `cloudify deployment delete` refuses a v2 manifest or active claims and points to application teardown (Phase 8.2).

## 8. What G2 does not claim

No claim of multi-operator write safety: the declared boundary is one local
filesystem and one host lock (Phase 6 non-breakage).
No claim that the first Phase 2 slice is small: it touches four `lib/` files plus
the router, and the compatibility period in section 5 is what makes it
revertable.
No claim that pinning is safe without the rotation command.
No claim about ivps: nothing in this plan writes to it.
