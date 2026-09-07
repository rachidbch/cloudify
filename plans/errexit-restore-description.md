# Change A — real-errexit restore in recipe sourcing: description + audit

Artifact of the CRITICAL-GATE description phase for change A (restructure the
if-condition subshells in `pkg_depends` + `cloudify_configure_package` so recipe
commands run with real `set -e`). Written READ-ONLY from the code, before any
edit. All bash-semantics claims below were verified empirically (repro scripts
in `/tmp/errexit_audit/`, run with bash 5.x, `set -Eeuo pipefail` context) unless
cited as code evidence.

## 1. Dispatch/sourcing chain and its invariants

### 1.1 Router dispatch (cloudify)

- `main()` (cloudify:319) parses flags, then per action block calls
  `_cloudify_dispatch "$action" "$hosts" "$packages"` (cloudify:520/530).
- `_cloudify_dispatch` (cloudify:243): for `localhost` calls
  `_cloudify_execute_package_action "$action" "${pkgs[@]}"`; for remote hosts
  calls `cloudify_remote "$host" "$packages"` (cloudify:302) which SSHes the
  envsubst payload template and then runs `cloudify $*` **again on the remote**
  (lib/remote.sh `cloudify_remote_payload_template` + `cloudify_remote_sync`,
  remote.sh:280: `cloudify_remote_payload="$cloudify_remote_payload; cloudify $*"`).
  So remote installs go through the exact same router and the exact same
  functions below, in a fresh process with `_CLOUDIFY_PKG_DEPTH` unset.
- `_cloudify_execute_package_action` (cloudify:204):
  - `install` on localhost: first `@default` packages **synchronously**, guarded:
    `if ! cloudify_install_package $defaults; then msg "... NOT attempted"; exit 1; fi`
    (cloudify:225) — an errexit-masked call site (see §2.1). Then the requested
    packages in a **backgrounded subshell**:
    `(export CLOUDIFY_FORCE=true; ...; cloudify_install_package "${pkgs[@]}") &`
    (cloudify:237) — an errexit-ACTIVE call site. `--clear-data` also sets
    `CLOUDIFY_FORCE=true` (cloudify:350-351).
  - `configure`: `(cloudify_configure_package "${pkgs[@]}") &` (cloudify:241) —
    ACTIVE. Configure never sets FORCE (run phase only).
  - The router then `wait "$_bg_pid"`s each bg pid and marks the host
    FAILED/OK by its exit code (cloudify:546-560).
  - `--verify`/`cloudify verify` bypass install entirely: `_cloudify_run_verify`
    per package in a bg subshell (cloudify:256-260, 430-439).

### 1.2 `cloudify_install_package` (lib/packages.sh:255)

Loops `pkg_depends "$pkg"` **bare** (one package per call) for non-tag args.
Because this call is bare and errexit is on in the ACTIVE call sites, a
`pkg_depends` that returns 1 today already kills the enclosing bg subshell
(host FAILED) — the "fail-fast across user-requested packages" behavior is
pre-existing, delivered by errexit at this level.

### 1.3 `pkg_depends` (lib/package-api.sh:395) — the recipe sink

Per package in `"$@"`:
1. `cloudify_is_package` → native-apt fallback path
   `if ! ( pkg_apt_install "${pkg}" ); then ...` (package-api.sh:443/451) —
   NOT touched by change A (still masked inside — apt failures record and the
   loop continues; deliberate die-containment, per the comments).
2. Recipe path: resolve via `cloudify_package_recipe_path`, then source the
   phases **inside an if-condition subshell** (package-api.sh:412 dep branch,
   :419 explicit branch):
   - dep branch (`_CLOUDIFY_PKG_DEPTH > 0`): the subshell is
     `(_CLOUDIFY_PKG_DEPTH=$((_CLOUDIFY_PKG_DEPTH + 1)) unset CLOUDIFY_FORCE;
     unset CLOUDIFY_CLEAR_DATA; _cloudify_source_pkg_phases "$pkg" "$recipe")`.
     The depth increment is a var-assignment prefix on the `unset` command only.
     Bash does NOT persist prefix assignments across special builtins in default
     (non-posix) mode — empirically `D=$((D+1)) unset FOO; func` sees D
     unchanged (m11.sh). So the dep branch increments NOTHING: the phases call
     runs at the caller's depth. Since nothing anywhere reads the depth beyond
     the `> 0` test (grep: only package-api.sh:400/409/412/419 and two unit
     tests set it to 0/1), the bug is behaviorally invisible today.
   - explicit branch: `(_CLOUDIFY_PKG_DEPTH=$((_CLOUDIFY_PKG_DEPTH + 1))
     _cloudify_source_pkg_phases ...)` — here the prefix DOES apply for the
     duration of the phases function (function call, not builtin), so explicit
     recipes and their own nested `pkg_depends` see depth+1. Correct today.
3. After a successful phases run: copy `pkg/<name>/*.script` files into
   `$CLOUDIFY_LOCAL_BIN` (guarded `if ! cp ...`, package-api.sh:427-436).
4. Verify hook (deep verify): `if [[ "$CLOUDIFY_NO_VERIFY" != true ]]; then
   _cloudify_run_verify "$pkg" || { failed_packages+=("$pkg"); continue; }; fi`
   (package-api.sh:459-462) — unchanged by A.
5. Any recorded failure → at the end `return 1` after printing
   "Failed packages:" (package-api.sh:465-471).

### 1.4 `_cloudify_source_pkg_phases` (lib/package-api.sh:380)

`source "$recipe_path" || return 1`, then if `cloudify_package_configure_path`
resolves (split pkg, ADR-008: install.sh preferred, init.sh legacy fallback;
configure.sh sibling) `source "$configure_path" || return 1`. Runs inside the
caller's subshell so install-phase vars/state are visible to the configure
phase. **Invariant**: an install.sh top-level `return 0` (the split-pkg install
guard) executes in the phases FUNCTION context, so it returns from
`_cloudify_source_pkg_phases` and skips the configure source entirely — the
fixture-split/k3s/xfce/guacamole/deepseek install guards rely on exactly this
(skip configure when the install guard trips; `cloudify configure <pkg>` runs
configure.sh standalone through `cloudify_configure_package`).

### 1.5 `cloudify_configure_package` (lib/packages.sh:168)

Same pattern, run-phase only:
`if ! ( _CLOUDIFY_PKG_DEPTH=1 source "$configure_path" ); then
failed_packages+=("$pkg"); continue; fi` (packages.sh:193) — depth pinned to a
constant 1, source direct (no `_cloudify_source_pkg_phases`), no install guard,
no FORCE/CLEAR_DATA semantics. Then the same verify hook.

### 1.6 FORCE / CLEAR_DATA / depth semantics

- `CLOUDIFY_FORCE=true` + `CLOUDIFY_CLEAR_DATA=true` are set by the router for
  explicit installs (cloudify:236-237, 350-351) and are **forwarded to remote
  hosts** via the envsubst allow-list (remote.sh template). Recipes test them in
  install guards to skip when already installed.
- Depth `_CLOUDIFY_PKG_DEPTH` defaults to 0 via `: "${_CLOUDIFY_PKG_DEPTH:=0}"`
  (package-api.sh:400). Explicit dispatch → the phases subshell runs with depth
  1 → the recipe's own `pkg_depends` calls see 1 > 0 → **dep branch** → their
  subshell `unset CLOUDIFY_FORCE; unset CLOUDIFY_CLEAR_DATA` so dependency
  recipes skip destructive re-installs (invariant: deps never see FORCE). Depth
  is never exported and never reset mid-run; nested deps under the broken dep
  branch all see the same >0 value (semantically correct outcome anyway).

### 1.7 Recipe resolution

`cloudify_package_recipe_path` (packages.sh:110) resolves
`[version.]distro.os.<file>` → `[distro.]os.<file>` → `<file>` for
install.sh/init.sh (install.sh preferred when present) or the explicit filename
(configure.sh via `cloudify_package_configure_path`). `verify.sh` resolved by
sibling dir of the resolved recipe (`cloudify_package_verify_path`).

### 1.8 Die / shadow semantics

- `die` = msg + `exit $code` (utils.sh:122). A `die` inside a recipe exits the
  phases subshell with that code.
- Shadows (lib/shadows/*.sh) override `sudo`, `apt-get` (+`apt`),
  `add-apt-repository`, `git`; they implement idempotency/auto-update
  (apt-get install of an already-installed pkg is a no-op success), password
  injection, and return nonzero only for genuine failures. Recipe-side bare
  calls to `apt-get`/`sudo`/`git` therefore hit the shadows; genuine failures
  return nonzero.

### 1.9 The masked-context invariant (the bug A addresses)

Empirically established (errexit-repro.sh, errexit-matrix2.sh, m9.sh, m10.sh):
a subshell that IS an `if`/`while`/`until` condition runs its whole body with
errexit suspended, and this suspension **propagates through nested function
calls and their plain-statement subshells** (m9: phases-as-if-condition masks a
mid-recipe `cd` failure; the recipe's own `set -e` does NOT pierce it, m9 case
2 + m10 X1). Therefore today EVERY recipe executes with errexit inert in every
dispatch path (both sites are if-conditions), regardless of outer caller
context. Consequences:
- a bare failing command mid-recipe continues silently; the phases subshell's rc
  is its LAST command's status — a recipe that fails early but ends successfully
  reports SUCCESS (m9 case 1/2), a recipe whose last command fails reports
  failure only at the end.
- xfce/install.sh documents this exact trap: "recipes run sourced inside
  pkg_depends' `if ! ( ... )` subshell, so errexit is SUSPENDED - every
  failure-prone command needs explicit `|| die`; never rely on set -e here."

## 2. Empirical bash matrix underpinning the verdicts

| construct (set -Eeuo pipefail) | outcome |
|---|---|
| `if ! ( cd /nope; echo )` | inside: cd fails, echo still runs (masked); `!` inverts last rc |
| function as if-condition | whole body + nested plain `( )` masked (m9, D) |
| `set -e` issued inside the masked subshell/file | still masked — cannot pierce (m10 X1, m9 rec2) |
| plain `( cd /nope; echo )` in ACTIVE context | cd fails → subshell dies rc=1 → caller errexit kills shell before next stmt (A) |
| `false && echo` / `! true` | shell survives; list rc propagates but no exit |
| `true && false` (final chain member fails) | errexit fires |
| any pipeline stage failing under pipefail | pipeline rc≠0 → errexit fires (m6: `false\|true` exits) |
| if/while/until BODY commands | errexit-active (m4); only the CONDITION is exempt |
| `x=$(false)` (assignment, active) | errexit fires (m5) |
| bats `run f` (f returns 1 / fails inside) | masked — `run` disables errexit; bare stmts in @test body ARE active (t2.bats) |
| `VAR=x unset FOO` (prefix on special builtin) | prefix NOT persisted in default bash (m11) |

## 3. Verdict per claim

a. **CONFIRMED** — with two scope caveats: (i) the behavior flip applies only in
   errexit-ACTIVE caller chains (user-requested installs local+remote via the
   bg subshell at cloudify:237, `init`'s `cloudify_install_package required`,
   `cloudify_configure_package` via cloudify:241, and `cloudify_install_default_
   packages`); the `@default` path (cloudify:225 `if ! cloudify_install_package
   $defaults`) stays masked THROUGH the whole nested chain even after A (mask
   propagates into plain subshells; set -e cannot pierce), so @default
   silent-continuation is NOT fixed by A and needs a router-side restructure.
   (ii) the full audit of newly-aborting bare commands is §4. xfce is the
   pattern the change rewards (fully `|| die` guarded, comment at
   xfce/install.sh:~57).
b. **CONFIRMED** — packages.sh:193 `cloudify_configure_package` uses the same
   `if ! ( ... )` pattern; restructure it in the same change or configure-phase
   recipes keep silent-continue while install-phase recipes abort (inconsistent
   semantics for the same configure.sh across `cloudify install` vs
   `cloudify configure`).
c. **CONFIRMED** — in ACTIVE paths a bare `pkg_depends X` in a recipe returns 1
   → the bare call fails under real errexit → the phases subshell aborts at that
   point (dep failures abort the parent recipe). Today it is silent-continue.
   Multi-arg `pkg_depends a b c` calls lose their continue-across-deps behavior
   in active paths (basics:3, gitless:10, leanmacs:5, required:5/8/11, piface:20,
   guacamole/install:19, hermes-signal:29, yazi:17, open-webui:47, affine:30,
   bash-it:5, fzf:5, dotfiles:7, paping:4, restic:5, gh:5, hub:4, grv:3, hugo:3,
   jump:3, scaleway:3, rclone:4, python deps...).
d. **CONFIRMED** (broken today; fix neutral) — empirically the increment is lost
   (m11), so dep-branch recipes run at the caller's depth. Nothing reads depth
   beyond the `> 0` branch test (grep over lib/, cloudify, tests), so no code
   depends on the broken value; moving the increment to the phases call makes
   depth bookkeeping correct with zero observable behavior change today.
e. **CONFIRMED** — top-level `return 0` in a sourced install.sh executes inside
   `_cloudify_source_pkg_phases` and returns from it, skipping the configure
   source — identical before/after A because the source/function mechanics are
   untouched (fixture-split:9, k3s-agent:9, k3s-server:9, xfce:47, guacamole:80,
   deepseek-harness:32, affine:23, hermes-dashboard:29, hermes-signal:35,
   hermes:8, open-webui:33, youtube-mcp:31, piface:15, wezterm:15, ufw:6,
   mariadb:10, mysql:12, mosh:9, miniconda3:8, mise:10, rclone:8, spacemacs:9,
   dotfiles:12, bash-it:10, leanmacs:10, fzf:10, restic:9, hunk:13, node:10).
f. **CONFIRMED** — `die` = exit, always exits the phases subshell with its code;
   identical before/after A. Caveat: what happens AFTER the subshell differs in
   ACTIVE paths (see j-1): today the if-branch records + continues + prints the
   "Failed packages:" summary; after A, errexit exits the process at the failing
   statement, before any summary.
g. **CONFIRMED** — commands in if/while/until conditions, in `&&`/`||` lists
   (except final element), under `!`, and non-last pipeline members keep their
   errexit exemption; only the recipe's reachable statement positions change.
   Also `X && Y` where X fails never exits the shell (tested) — such guards stay
   safe.
h. **CONFIRMED** — `_cloudify_run_verify` (package-api.sh:341) and its call
   sites (`... || { failed_packages+=...; continue; }`) are untouched by A; its
   retry loop `if last_err=$( { source "$verify_path" && pkg_verify; } 2>&1 )`
   remains an if-condition (masked inside) exactly as today, heartbeats intact.
i. **CONFIRMED** — `local _rc` must be declared in the enclosing function
   (`pkg_depends`/`cloudify_configure_package` are both functions; precedent:
   `local configure_path` in the same loop). Deeper issue: see j-1 — in ACTIVE
   contexts the statement aborts the process before `_rc` is read, so this
   bookkeeping is reachable only in masked contexts.
j. **CONFIRMED, several second-order effects** (detailed in §5).

## 4. Audit — unguarded, errexit-applicable, failure-prone commands in pkg/*

Method: scanner (lexical parse of all 97 install.sh/configure.sh/init.sh files,
classifying each statement position for errexit-applicability, pipefail,
exemption contexts; ~245 raw candidates) + full manual review of every file
with real candidates. Below is the curated list — commands at positions that
WILL newly abort under A in ACTIVE paths (install/configure dispatch, init).
Verified-guarded commands (`|| die`, `|| true`, if-condition, while-until
condition, async, mid-chain) are excluded.

High-confidence list (file:line — command):

affine/init.sh:31 mise use -g node@lts; :32 node --version; :52 npm ci; :55 mkdir -p "$HOME/.config/systemd/user"; :80 systemctl --user daemon-reload; :81 systemctl --user enable affine-mcp; :82 systemctl --user restart affine-mcp; (:30 pkg_depends git mise)
apache/init.sh:3 apt-get install -y apache2 (single-cmd recipe — end-state unchanged)
bash-it/init.sh:33 git clone; :38 "$HOME"/.bash_it/install.sh -n
bat/init.sh:5, bats-test:5, digitalocean:3, fd:3, gh:6, grv:4, hub:5, hugo:4, jump:4, lab:4, pandoc:4, paping:5, scaleway:4, yq:2, rclone:18, restic:19 — pkg_install_release (internal curl/jq/die; failing = genuine)
basics/init.sh:3 pkg_depends tree procps jq rename pandoc moreutils (multi-dep)
croc/init.sh:4 curl -sL https://getcroc.schollz.com | bash  (pipefail)
deepseek-harness/install.sh:49 ln -sf "$DSH_BIN" /usr/local/bin/dsh; :66 mkdir -p /opt; :130 systemctl daemon-reload; :131 systemctl enable --now dsh
deepseek-harness/configure.sh:25 NEW="$(npm ls -g @deepseek-ai/dsh 2>/dev/null | grep -oE '@deepseek-ai/dsh@[^ ]+' | head -1)" — grep-no-match aborts (line 21 PREV has `|| true`, safe); :64 systemctl daemon-reload; :65 systemctl restart dsh
docker/init.sh:14 install -m 0755 -d /etc/apt/keyrings; :15 curl -fsSL ... -o /etc/apt/keyrings/docker.asc; :16 chmod a+r ...; :20 . /etc/os-release; :21 DOCKER_ARCH=$(dpkg --print-architecture); :35 docker -v; :38 sudo usermod -aG docker "$USER" (all non-root /etc writes silently no-op today as non-root)
dotfiles/init.sh:38/39 ln -sfn; :42 "$HOME"/.local/bin/stowit
emacs-nox/init.sh:4 DISTRO_VER="$(cloudify_osdetect --version)"
entr:5, git:4, gpg2:3, json:2, rsync:3, ssh:2, xsel:2 — single apt-get (end-state unchanged)
fasd/init.sh:4 pkg_apt_repository; :5 pkg_apt_install fasd
fzf/init.sh:25 "$HOME"/.fzf/install --bin; :28 ln -sfn
go:4 / nvm:4 / pyenv:4 — ~/.local/bin/mise use -g <lang>@latest
guacamole/install.sh:169 sudo docker compose ... up -d postgres guacd; :181 PG_CID="$(... ps -q postgres | head -n1)"; :190 _schema_present="$(sudo docker exec ... psql ... | tr -d ...)"; :223 chmod 600
guacamole/configure.sh:123 sudo docker compose up -d; :145/146 _token/_ds="$(printf ... | jq -r ...)"; :150-152 _id="$(curl -fsS ... | jq -r ... | head -n1)" — REST hiccup aborts where today it silently retried via the create path
hermes/init.sh:17 curl -fsSL ... | bash -s -- --skip-setup (pipefail)
hermes-dashboard/init.sh:61 systemctl --user daemon-reload; :62 enable hermes-dashboard; :63 start hermes-dashboard
hermes-openwebui/init.sh:70-80 get_hermes_var()'s val="$(grep -E ... | cut ...)" + :82-85 API_SERVER_*=$(get_hermes_var ...) — grep-no-match on an .env missing any API_SERVER_* key ABORTS (false-abort risk; the recipe's own :91-94 adds the key when absent)
hermes-signal/init.sh:45 mkdir -p /opt/signal-gateway/data; :81 systemctl daemon-reload; :82 systemctl enable --now hermes-signal-gateway; :85-86 cp link-device.sh (root-only writes)
hunk/init.sh:22 mkdir -p /opt/hunkdiff; :23 npm install -g --prefix /opt/hunkdiff hunkdiff; :25 ln -sf ... /usr/local/bin/$bin (root-only)
keepassxc/init.sh:5 add-apt-repository ppa:phoerious/keepassxc -y; :6 apt-get install -y keepassxc; :13 git clone ...kip.git; :15 sudo install ... /usr/local/bin/
k3s-agent/install.sh:28 mkdir -p /var/lib/rancher/k3s/agent/images /etc/rancher/k3s; k3s-server/install.sh:28 same
k3s-agent/configure.sh:14 TS_IP="$(tailscale ip -4 2>/dev/null | awk '{print $1}')" (tailscale down/missing → 127; the :15 `|| die` fallback becomes unreachable-in-practice but behavior stays an abort); :17 mkdir; :57 systemctl daemon-reload; :59 systemctl restart k3s-agent.service; k3s-server/configure.sh mirrors (:11/:13 assignments, :68/:70 systemctl)
k3s-cli/init.sh:31 mkdir; :34 scp; :38/43 sed; :52 kubectl ...; :51/53 cp/mv (FINAL_ANDOR)
leanmacs/init.sh:16 mv ~/.emacs.d ~/.emacs.d.bak (if-body); :18 ln -sfn; :26 mkdir
lexicon/init.sh:7 python3 -m pip install --user git+https://...
megadown/init.sh:9 rm -f (via `[ -d ] && rm`); :10 git clone; :11 chmod; :12 cp -f ./git/megadown "$LOCAL_BIN"/ — $LOCAL_BIN is UNSET in-recipe → cp to "/" → fails as non-root (latent bug, surfaced)
miniconda3/init.sh:18 curl ... > miniconda3.sh (CWD-relative write); :22 source ./miniconda3.sh
mise/init.sh:13 curl -sSL https://mise.run | sh (pipefail)
mosh/init.sh:16 touch ~/.hushlogin; :20 sudo locale-gen en_US.UTF-8 (if-body)
mysql/init.sh:24 curl ... > mysql.deb; :27 apt-get install -y ./mysql.deb (if-body)
neovim/init.sh:7 python3 -m pip install --user --upgrade pynvim
open-webui/init.sh:51 mkdir -p /opt/open-webui/data; :131-132 systemctl daemon-reload; systemctl enable --now open-webui (root-only)
php/init.sh:33 curl -L -O ...phpbrew (subshell in if-body); :46-48 wget/php -r; :57 sudo php composer-setup.php; :64 sudo chown; :65 composer global require; :71 apt-get install -y php-sqlite3; :74 wget manual
piface/init.sh:24 mise use -g node@lts; :41 ln -sf ... /usr/local/bin/pi; :45 uv tool install --python 3.12 --force piface; :48 install -m 0755 ... /usr/local/bin/piface-set-key; :75-77 systemctl --user daemon-reload/enable/restart (root-only writes)
pip/init.sh:11/19 wget get-pip.py; :14/22 sudo -H python3/python2 (if-bodies; python2 URL is dead upstream — will abort loudly now)
pipx/init.sh:14 python3 -m pip install --user pipx; :15 python3 -m pipx ensurepath
play/init.sh:2 git clone ... /tmp/cloudify/play
python/init.sh:2 UBUNTU_VER="$(lsb_release -r | cut -f2)" (lsb_release absent on minimal images → abort)
rclone/init.sh:24 cat template | envsubst | tee ... (pipefail; missing template aborts — the unconditional "Created" msg after it is today's silent lie)
restic/init.sh:26-28 sudo cp/chown/chmod resticfy; :32-34 mkdir/touch; :50 sudo tee cron; :53 sudo chmod (root, unguarded)
sdkman/init.sh:34 curl -s ... | bash (pipefail; own `set -e` at :2 stays inert today, redundant after A in active paths)
snipster/init.sh:5-8 pyenv virtualenv/activate/(cd git && pip install)/deactivate (relative ./git dir; fragile either way)
tern/init.sh:5 npm i -g tern
tmux-compile/init.sh:3 apt-get remove -y tmux; :5 wget ...tmux-2.6.tar.gz; :9 ./configure; :10 make; :11 sudo make install; :13/14 sudo rm/mv (whole source build aborts on first genuine failure)
todo.txt/init.sh:8 wget (via `[ -e ] || wget`); :10 mkdir; :11 tar xzvf; :15 sudo mv (subshell)
ufw/init.sh:10 sudo ufw allow OpenSSH; :11 sudo ufw enable (pre-existing SSH-drop hazard, unchanged class)
virtualenv/init.sh:3 `[ -z "$(which virtualenv)" ] || python3 -m pip install --user virtualenv` — INVERTED guard (installs when already present); pip is the || -final member
wezterm/init.sh:18 curl -LO ...; :20 rm -f (cleanup)
xfce/install.sh:42/44 pkg_apt_install ... (die-guarded); :67-93 chrome block all die-guarded; :170-178 sudo usermod ... || true / sudo systemctl enable --now xrdp (unguarded) / sudo systemctl restart xrdp (unguarded, if-body); xfce/configure.sh:23 _home="$(getent ... | cut)"; :48 sudo ln -sf; :51 sudo systemctl enable --now xrdp; :53 restart
yazi/init.sh:19 YAZI_VERSION="$(curl -s api.github... | grep -Po ...)" (GitHub rate-limit or no match → abort); :31 mkdir; :32 curl -fsSL ... yazi.zip; :33 unzip; :38-47 sudo install x8; :49 rm -rf /tmp/yazi
youtube-mcp/init.sh:53 npm install; :55 npm run build; :94 systemctl daemon-reload; :95 systemctl enable --now youtube-mcp (root-only /opt /etc)

Machine count: 245 raw candidates across 84 of the 97 phase files; after
dedup of scanner noise (heredoc markers, continuation args, safe commands,
guarded chains) and review, roughly **150 genuine unguarded, errexit-applicable
statements** listed above. Note most recipes also carry 1-4 cloudify-API calls
(pkg_apt_install/pkg_depends/pkg_install_release) that now abort on genuine
failure — desired for single calls; multi-pkg pkg_depends lose continue (j-3).

False-abort RISK subset (failures that occur in NORMAL operation, not
exceptional; aborting here would break installs that succeed today):
1. hermes-openwebui/init.sh:82-85 — grep-no-match when any API_SERVER_* key is
   absent from $HOME/.hermes/.env (the :91-94 auto-add path never reached).
2. deepseek-harness/configure.sh:25 NEW=... — grep-no-match if `npm ls -g`
   output lacks the pin (fresh npm cache / alternate install).
3. yazi/init.sh:19 — unauthenticated api.github.com rate limiting.
4. python/init.sh:2, k3s-*:TS_IP, guacamole:181/190, emacs-nox:4 —
   cmdsubst/pipeline assignments whose inner command can legitimately fail or be
   absent (lsb_release, tailscale down, docker exec hiccup).
5. Env-dependent hard flips: non-root runs of root-only-write recipes
   (docker, hermes-signal, open-webui, k3s-*, youtube-mcp, piface, hunk,
   deepseek-harness ln) currently "succeed" by masking; after A they abort at
   the first /etc /opt /usr/local write. Integration tests run as root
   (helpers/integration.bash: root@cloudify) so this class is invisible to CI.
   Whether recipes are meant to run as root or via sudo is a house decision the
   change forces.

## 5. Residual risks and second-order effects NOT solved/created by A

1. **j-1 — the proposed bookkeeping is unreachable in ACTIVE paths.** Under
   real errexit, a failing plain `( phases )` statement kills the enclosing
   function's process BEFORE `local _rc=$?` executes (proven: errexit in a
   function body in an active context exits the shell, test A). So in exactly
   the paths where A works, `failed_packages+=...; continue` and the "Failed
   packages:" summary never run — failure surfaces as process exit rc (host
   FAILED via the router `wait`), subsequent packages/deps in the same call are
   skipped, and mid-recipe bare failures (`false`) print no diagnostic (bash
   errexit is silent; the ERR trap runs cleanup, not an echo). The summary/count
   path only executes in masked callers (@default, bats `run`) where A changes
   nothing. If preserving the summary + continue semantics matters, the
   bookkeeping needs a different mechanism (e.g. subshell isolation with the
   recipe run as an explicit child, or an ERR-trap that echoes `line N`).
2. **j-2 — @default silent-continuation is NOT fixed by A.** The mask at
   cloudify:225 propagates through the whole chain into the phases subshell and
   cannot be pierced by `set -e` anywhere inside (m9, m10-X1). The router's
   `if ! cloudify_install_package $defaults` wrapper still only catches
   end-of-call failures. Fixing @default requires restructuring that call site
   too — out of scope of A as written.
3. **j-3 — multi-dep continue semantics lost in ACTIVE paths.** A failing dep in
   `pkg_depends a b c` aborts the pkg_depends loop at `a` (errexit before the
   bookkeeping); today b and c are attempted and only the summary reports.
4. **j-4 — ERR trap now fires mid-recipe.** `trap cleanup ... ERR` (cloudify:77,
   lib modules set -E) runs `cleanup`, which `rm -rf`s `$CLOUDIFY_TMP` content
   (excluding logs) on EVERY new mid-recipe failure in active paths (previously
   only on exit/die). Cleanup already runs at exit via the EXIT trap, but now it
   can delete pkg_backup/state mid-run and, on a multi-host run, clobber the
   shared /tmp/cloudify of sibling host processes. DEBUG mode skips it.
5. **j-5 — a recipe's own `set -e` (sdkman:2) stays inert today and is simply
   redundant after A** — no double-failure semantics.
6. **Residual masked spots A deliberately does not touch**: native-apt fallback
   in pkg_depends (`if ! ( pkg_apt_install ... )`), the verify retry loop, and
   the @default chain (j-2). A "partial masking" of multi-package
   `pkg_apt_install a b c` still exists: the apt-get shadow loops packages
   internally and returns after attempting all — a genuine failure of one apt
   package aborts the whole recipe under A without per-package granularity
   (pkg_apt_install has no partial-failure reporting to give).
7. **Recipe behavior deltas beyond aborts**: docker -v / node --version / mise
   use sanity lines abort on absence (fine); `docker compose up` failures abort
   immediately instead of the previous 4-minute masked until-loop (guacamole);
   guacamole REST mid-function failures abort at first curl -f (better);
   hermes-openwebui/hunk/piface etc. flip from silent-success (as root) to
   nothing-new (as root) — the change only bites non-root, where it converts
   silent no-ops into honest failures.

## 6. Test-suite coverage assessment + recommended pre/post set

Current safety net vs A:
- tests/unit/package-api.bats: pkg_depends error-collection tests
  ("isolates recipe failures in subshell" L378, "collects errors" L335,
  "continues after a package fails" L355, "isolates native-path failures"
  L404, ".script copy fails" L431). **All run through bats `run` = masked**
  (t2.bats) → they will PASS unchanged before and after A and CANNOT detect A's
  behavior delta. They encode the aggregate/continue/summary contract that
  becomes dead code in active paths after A (they still pass because they run
  masked).
- tests/unit/packages.bats (C1 FORCE/depth tests L145-195) exercise the
  dep-branch/explicit-branch depth routing via `run` (masked) — regression-net
  for the restructure's var handling, but depth>0 assertions won't catch the
  dep-branch increment bug either way.
- tests/integration/package-install-run-split.bats: real `cloudify --on`
  fixture runs through the ACTIVE bg path; covers dep-pull → configure ordering,
  guard return-0 skipping, configure-only dispatch, env forwarding to
  configure, post-configure verify failure. All fixtures end successfully, so
  they guard the CONTROL FLOW of both restructured sites but cannot detect a
  silent-continue regression (no failing mid-recipe fixture).
- tests/integration/package-guacamole.bats: heaviest real recipe (|| die
  style) — good regression net that die-guarded recipes behave identically.
- tests/integration/package-remote-vars.bats: env-forwarding/verify paths,
  untouched by A.
- Unit + integration suites run inside the Incus container as root and are
  gated on `git push` first (Taskfile) — root-only execution hides the
  non-root env-dependent flips (risk §4.5).

Recommended targeted tests:
1. Discriminator (pre: red, post: green): a fixture pkg whose recipe has a bare
   failing command followed by a successful command, installed via
   `cloudify --no-defaults --on <host> install fixture-errexit` (ACTIVE path):
   pre-A status 0 (silent lie), post-A status != 0 and the trailing marker file
   absent. Same for the configure action with a failing configure.sh.
2. @default-path discriminator: `cloudify install <pkg>` WITHOUT --no-defaults
   where a @default recipe carries a mid-recipe bare failure — documents the
   j-2 gap (stays 0 after A) or, if the desired semantics is abort, red until
   the router call site is restructured.
3. Dep-abort unit/integration: recipe A pkg_depends B where B's recipe fails —
   assert post-A the install fails and A's later steps did not run (claim c).
4. Guard/regression (must stay green post-A): existing fixture-split suite
   (dep-pull → configure ordering, return-0 guard), package-api pkg_depends
   error-collection suite (masked — still passes), package-guacamole,
   package-remote-vars, unit C1 FORCE/depth tests.
5. Depth-branch unit: recipe that calls pkg_depends from inside a dep and
   echoes `_CLOUDIFY_PKG_DEPTH` — pins the (currently broken) increment so the
   moved increment in A is observable.
6. Full-suite regression run post-change (task test + task lint), since every
   integration pkg install now exercises real errexit for the first time.

## Artifact disposition

This file is the required written artifact for the cloudify CRITICAL GATE.
Change A is NOT approved by this document; per the gate, an implementation plan
arguing non-breakage (§3-§5 findings addressed: reachability of the bookkeeping
j-1, @default gap j-2, ERR-trap j-4, the false-abort risk list §4, audit-clean
recipe set §4) and explicit human consent are still required before any edit.
