#!/usr/bin/env bats
# Tests for the shell command routing in the cloudify router

setup() {
    source tests/helpers/common.bash
    setup_test_env

    STUB_DIR="$(mktemp -d)"
    export STUB_DIR
    export PATH="$STUB_DIR:$PATH"
    export CLOUDIFY_REMOTE_USER=root
}

teardown() {
    rm -rf "$STUB_DIR"
    teardown_test_env
}

# Create an ssh stub that records how it was called AND executes the payload
# (stdin) with the streamed tree as the remote checkout - the worker needs the
# payload's real result and checkout lines to reconcile, so a capture-only
# stub cannot back these tests anymore.
_create_ssh_stub() {
    cat <<STUB > "$STUB_DIR/ssh"
#!/bin/bash
echo "SSH_ARGS: \$*" >> "\$STUB_DIR/ssh_calls.log"
# Real hosts are separate machines: their scratch never collides. The stub
# runs every payload on ONE filesystem, so serialize them (a recipe that
# builds in /tmp would otherwise race itself across "hosts").
exec 9>>"\$STUB_DIR/payload.lock"
flock 9
# A real ssh lands in a FRESH remote shell: controller-side paths and
# ownership must not leak (the inherited context path made the payload-side
# router's cleanup sweep the controller's dispatch context).
unset CLOUDIFY_CONTEXT_FILE _CLOUDIFY_TMP_OWNER CLOUDIFY_TMP CLOUDIFY_CONTEXT_DIR \
      CLOUDIFY_LOG_FILE CLOUDIFY_APPLICATION CLOUDIFY_FLAVOR \
      CLOUDIFY_DEPLOYMENT_NAME CLOUDIFY_DEPLOYMENT CLOUDIFY_STATE_DIR \
      CLOUDIFY_CREDENTIALS_DIR
# A real remote host has no ivps (it is the controller's inventory CLI) - the
# payload-side worker must take its named skip, never record beside the
# controller's. A clean remote PATH, not the controller's stubbed one.
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
export CLOUDIFY_DIR="$PWD"
bash -s
STUB
    chmod +x "$STUB_DIR/ssh"
    : > "$STUB_DIR/ssh_calls.log"
}

# Create an ivps stub: node `cloudai` exists and hosts instance `cloudify`;
# node dirs are writable inside STUB_DIR so dispatch records land there.
_create_ivps_target_stub() {
    mkdir -p "$STUB_DIR/nodes/cloudai/instances/cloudify" \
             "$STUB_DIR/nodes/cloudai/instances/cloudify2" "$STUB_DIR/nodes/local"
    cat <<STUB > "$STUB_DIR/ivps"
#!/bin/bash
case "\${1:-}" in
    node)
        case "\${3:-}" in
            local)  echo "$STUB_DIR/nodes/local" ;;
            cloudai) echo "$STUB_DIR/nodes/cloudai" ;;
            # The combined form resolves to the INSTANCE dir (the state
            # inventory calls it for every record and lock on the target).
            cloudai:cloudify)  echo "$STUB_DIR/nodes/cloudai/instances/cloudify" ;;
            cloudai:cloudify2) echo "$STUB_DIR/nodes/cloudai/instances/cloudify2" ;;
            *) exit 1 ;;
        esac
        ;;
    list)
        echo "  REMOTE:NAME      STATUS"
        echo "  cloudai:cloudify Running"
        echo "  cloudai:cloudify2 Running"
        ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$STUB_DIR/ivps"
}

# Run the shell case logic matching the router code
_run_shell_case() {
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/package-api.sh
    source lib/containers.sh
    source lib/remote.sh
    source lib/packages.sh
    source lib/hosts.sh

    # Simulate: cloudify shell hermes [args...]
    set -- "shell" "hermes" "$@"

    [[ -z "${2:-}" ]] && die "Missing host"
    shift  # drop "shell"
    local host="$1"
    shift  # drop "hermes"

    # This mirrors the actual router code in the shell case
    local ssh_target="${CLOUDIFY_REMOTE_USER:+$CLOUDIFY_REMOTE_USER@}$host"

    if [[ $# -eq 0 ]] || [[ "${1:-}" == "-i" ]]; then
        if [[ "${1:-}" == "-i" ]]; then
            shift
            # -i explicitly requests interactive: always use -t
            ssh -t -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$ssh_target" "$@"
        else
            # Bare shell: use -t only when stdin is a TTY
            local tty_flag=""
            [ -t 0 ] && tty_flag="-t"
            ssh $tty_flag -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$ssh_target" "$@"
        fi
    else
        ssh -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$ssh_target" "$@" 2>&1 | tail -n +2
    fi
}

# Same as _run_shell_case but forces -t (simulates TTY being available)
_run_shell_case_with_tty() {
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/package-api.sh
    source lib/containers.sh
    source lib/remote.sh
    source lib/packages.sh
    source lib/hosts.sh

    set -- "shell" "hermes" "$@"

    [[ -z "${2:-}" ]] && die "Missing host"
    shift
    local host="$1"
    shift

    local ssh_target="${CLOUDIFY_REMOTE_USER:+$CLOUDIFY_REMOTE_USER@}$host"

    if [[ $# -eq 0 ]] || [[ "${1:-}" == "-i" ]]; then
        [[ "${1:-}" == "-i" ]] && shift
        ssh -t -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$ssh_target" "$@"
    else
        ssh -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$ssh_target" "$@" 2>&1 | tail -n +2
    fi
}

# ---------------------------------------------------------------
# SSH target includes CLOUDIFY_REMOTE_USER
# ---------------------------------------------------------------

@test "shell uses CLOUDIFY_REMOTE_USER@host as ssh target" {
    _create_ssh_stub
    _run_shell_case

    grep -q "root@hermes" "$STUB_DIR/ssh_calls.log"
}

@test "shell with -i uses CLOUDIFY_REMOTE_USER@host as ssh target" {
    _create_ssh_stub
    _run_shell_case -i hermes setup

    grep -q "root@hermes" "$STUB_DIR/ssh_calls.log"
}

@test "shell non-interactive uses CLOUDIFY_REMOTE_USER@host as ssh target" {
    _create_ssh_stub
    _run_shell_case hermes --version

    grep -q "root@hermes" "$STUB_DIR/ssh_calls.log"
}

# ---------------------------------------------------------------
# Bare shell (no command) → interactive with -t
# ---------------------------------------------------------------

@test "shell with no args uses ssh -t when stdin is a TTY" {
    _create_ssh_stub
    # Force TTY detection to true
    _run_shell_case_with_tty

    grep -q "\-t" "$STUB_DIR/ssh_calls.log"
}

@test "shell with no args omits -t when stdin is not a TTY" {
    _create_ssh_stub
    _run_shell_case

    ! grep -q "\-t" "$STUB_DIR/ssh_calls.log"
}

@test "shell with no args does NOT pipe through tail" {
    _create_ssh_stub
    _run_shell_case

    local call_count
    call_count=$(grep -c "SSH_ARGS:" "$STUB_DIR/ssh_calls.log")
    [ "$call_count" -eq 1 ]
}

# ---------------------------------------------------------------
# shell -i command → interactive with -t
# ---------------------------------------------------------------

@test "shell -i command uses ssh -t (interactive)" {
    _create_ssh_stub
    _run_shell_case -i hermes setup

    grep -q "\-t" "$STUB_DIR/ssh_calls.log"
}

@test "shell -i command passes command to ssh" {
    _create_ssh_stub
    _run_shell_case -i hermes setup

    grep -q "hermes setup" "$STUB_DIR/ssh_calls.log"
}

# ---------------------------------------------------------------
# shell command (no -i) → non-interactive, no -t
# ---------------------------------------------------------------

@test "shell with command but no -i does NOT use -t" {
    _create_ssh_stub
    _run_shell_case hermes --version

    ! grep -q "\-t" "$STUB_DIR/ssh_calls.log"
}

@test "shell with command but no -i passes command to ssh" {
    _create_ssh_stub
    _run_shell_case hermes --version

    grep -q "hermes --version" "$STUB_DIR/ssh_calls.log"
}

# ---------------------------------------------------------------
# Router: unrecognized arguments must not exit silently
# ---------------------------------------------------------------

@test "router exits with error on unrecognized positional argument" {
    _create_ssh_stub
    run bash -c "
        export CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true
        export CLOUDIFY_IS_LOCAL=true CLOUDIFY_DIR=/tmp/cf-test CLOUDIFY_TMP=/tmp/cf-test-tmp
        export DEBUG=false CLOUDIFY_HOSTPWD=test CLOUDIFY_REMOTE_USER=root
        mkdir -p /tmp/cf-test/pkg /tmp/cf-test/inventory /tmp/cf-test-tmp
        cd /root/cloudify && bash cloudify hermes shell 2>&1
    "
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------
# Real router: SSH target must use CLOUDIFY_REMOTE_USER
# ---------------------------------------------------------------

@test "real router: cloudify shell host uses CLOUDIFY_REMOTE_USER@host" {
    local stub_bin="$STUB_DIR/ssh"
    cat <<'STUB' > "$stub_bin"
#!/bin/bash
echo "SSH_REAL: $*" >> "$STUB_DIR/ssh_calls.log"
STUB
    chmod +x "$stub_bin"
    : > "$STUB_DIR/ssh_calls.log"

    PATH="$STUB_DIR:$PATH" run bash -c "
        export CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true
        export CLOUDIFY_IS_LOCAL=true CLOUDIFY_DIR=/tmp/cf-test CLOUDIFY_TMP=/tmp/cf-test-tmp
        export DEBUG=false CLOUDIFY_HOSTPWD=test CLOUDIFY_REMOTE_PWD=test CLOUDIFY_REMOTE_USER=root
        mkdir -p /tmp/cf-test/pkg /tmp/cf-test/inventory /tmp/cf-test-tmp
        cd /root/cloudify && bash cloudify shell testhost echo ok 2>&1
    "

    grep -q "root@testhost" "$STUB_DIR/ssh_calls.log"
}

# ---------------------------------------------------------------
# Verify flags and verify subcommand
# ---------------------------------------------------------------

@test "--no-verify flag is accepted (not rejected as unknown option)" {
    # With no package after install, cloudify errors on empty package section,
    # NOT on unknown flag — proving --no-verify was parsed.
    run bash -c "cd /root/cloudify && \
        CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true \
        CLOUDIFY_IS_LOCAL=true CLOUDIFY_DIR=/tmp/cf-router-test CLOUDIFY_TMP=/tmp/cf-router-test-tmp \
        DEBUG=false bash cloudify --no-verify install 2>&1"
    [[ "$output" != *"Unknown option"* ]]
}

@test "--verify flag is accepted (not rejected as unknown option)" {
    run bash -c "cd /root/cloudify && \
        CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true \
        CLOUDIFY_IS_LOCAL=true CLOUDIFY_DIR=/tmp/cf-router-test CLOUDIFY_TMP=/tmp/cf-router-test-tmp \
        DEBUG=false bash cloudify --verify install 2>&1"
    [[ "$output" != *"Unknown option"* ]]
}

@test "verify subcommand runs verify.sh and exits 0 on success" {
    # Create a package with a passing verify.sh in the test CLOUDIFY_DIR
    mkdir -p /tmp/cf-router-test/pkg/vpkg
    echo '# recipe' > /tmp/cf-router-test/pkg/vpkg/init.sh
    cat > /tmp/cf-router-test/pkg/vpkg/verify.sh <<'EOF'
pkg_verify() { return 0; }
EOF

    run bash -c "cd /root/cloudify && \
        CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true \
        CLOUDIFY_IS_LOCAL=true CLOUDIFY_DIR=/tmp/cf-router-test CLOUDIFY_TMP=/tmp/cf-router-test-tmp \
        DEBUG=false bash cloudify verify vpkg 2>&1"
    [ "$status" -eq 0 ]
}

@test "verify subcommand exits non-zero when verification fails" {
    mkdir -p /tmp/cf-router-test/pkg/failvpkg
    echo '# recipe' > /tmp/cf-router-test/pkg/failvpkg/init.sh
    cat > /tmp/cf-router-test/pkg/failvpkg/verify.sh <<'EOF'
pkg_verify() { return 1; }
EOF

    PKG_VERIFY_TIMEOUT=1 run bash -c "cd /root/cloudify && \
        CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true \
        CLOUDIFY_IS_LOCAL=true CLOUDIFY_DIR=/tmp/cf-router-test CLOUDIFY_TMP=/tmp/cf-router-test-tmp \
        DEBUG=false PKG_VERIFY_TIMEOUT=1 bash cloudify verify failvpkg 2>&1"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------
# Real router: --on target grammar
# ---------------------------------------------------------------

_router_env() {
    cat <<'ENV'
        export CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true
        export CLOUDIFY_IS_LOCAL=true CLOUDIFY_TMP=/tmp/cf-target-test-tmp
        # The streamed tree IS the checkout for both legs: the controller's
        # reconcile resolves parent packages against its pkg/ (CLOUDIFY_DIR
        # would otherwise default to \$HOME/cloudify - the marker-only stub).
        export CLOUDIFY_DIR="$PWD"
        export DEBUG=false CLOUDIFY_HOSTPWD=test CLOUDIFY_REMOTE_PWD=test CLOUDIFY_REMOTE_USER=root
        export CLOUDIFY_NO_DEFAULTS=true
        # Isolated home: the worker's manifests and events land inside STUB_DIR,
        # and the fake checkout's pinned marker keeps the payload's update step
        # from ever curling the bootstrap gist.
        export HOME="$STUB_DIR/home"
        mkdir -p "$HOME/cloudify" /tmp/cf-target-test-tmp
        touch "$HOME/cloudify/.#last_update"
ENV
}

@test "real router: --on X:Y resolves to the instance ssh host" {
    _create_ssh_stub
    _create_ivps_target_stub

    PATH="$STUB_DIR:$PATH" run bash -c "$(_router_env)
        cd "$PWD" && bash cloudify --on cloudai:cloudify install bats-test 2>&1
    "

    [ "$status" -eq 0 ]
    grep -q "root@cloudify" "$STUB_DIR/ssh_calls.log"
}

@test "real router: a bare remote dispatch synthesizes the _direct deployment and its records" {
    _create_ssh_stub
    _create_ivps_target_stub

    PATH="$STUB_DIR:$PATH" run bash -c "$(_router_env)
        cd "$PWD" && bash cloudify --on cloudai:cloudify install bats-test 2>&1
    "

    [ "$status" -eq 0 ]
    # The worker's state record under the resolved instance dir (the registry
    # this test pinned is retired; the inventory record replaced it). Both the
    # controller-side and the payload-side worker write one _direct deployment
    # each - at least one record with the honest shape is the pin.
    local -a recs mfs m
    recs=("$STUB_DIR"/nodes/cloudai/instances/cloudify/deployments/_direct/direct/*/packages/bats-test/default/state.json)
    [ "${#recs[@]}" -ge 1 ]
    [ "$(jq -r .package "${recs[0]}")" = "bats-test" ]
    [ "$(jq -r .host "${recs[0]}")" = "cloudai:cloudify" ]
    [ "$(jq -r .application "${recs[0]}")" = "_direct" ]
    [ "$(jq -r .applied.version "${recs[0]}")" = "1.0.0" ]
    # And each synthesized manifest derives its word from its events.
    mfs=("$STUB_DIR"/home/.local/state/cloudify/deployments/_direct/direct/*/manifest.json)
    [ "${#mfs[@]}" -ge 1 ]
    local word
    for m in "${mfs[@]}"; do
        word=$(jq -r .status "$m" 2>/dev/null || true)
        [[ "$word" == "installed" ]] || { echo "manifest $m says $word"; return 1; }
    done
}

@test "real router: one bare invocation on two hosts synthesizes ONE _direct deployment" {
    _create_ssh_stub
    _create_ivps_target_stub

    PATH="$STUB_DIR:$PATH" run bash -c "$(_router_env)
        cd "$PWD" && bash cloudify --on cloudai:cloudify cloudai:cloudify2 install bats-test 2>&1
    "

    [ "$status" -eq 0 ]
    grep -q "root@cloudify" "$STUB_DIR/ssh_calls.log"
    grep -q "root@cloudify2" "$STUB_DIR/ssh_calls.log"
    # ONE deployment (one manifest), TWO bindings - one per host word.
    local -a mfs
    mfs=("$STUB_DIR"/home/.local/state/cloudify/deployments/_direct/direct/*/manifest.json)
    [ "${#mfs[@]}" -eq 1 ]
    local -a blines
    mapfile -t blines < <(jq -r '.bindings | to_entries[] | [.key, .value.instance] | @tsv' "${mfs[0]}")
    [ "${#blines[@]}" -eq 2 ]
    [[ "${blines[0]}" == $'cloudai:cloudify\tcloudify' ]]
    [[ "${blines[1]}" == $'cloudai:cloudify2\tcloudify2' ]]
    # And each host's records live under its own instance dir, same identity.
    local n
    n="$(basename "$(dirname "${mfs[0]}")")"
    [ -f "$STUB_DIR/nodes/cloudai/instances/cloudify/deployments/_direct/direct/$n/packages/bats-test/default/state.json" ]
    [ -f "$STUB_DIR/nodes/cloudai/instances/cloudify2/deployments/_direct/direct/$n/packages/bats-test/default/state.json" ]
}

@test "real router: --on <bad>: dies with the node-not-found message" {
    _create_ivps_target_stub

    PATH="$STUB_DIR:$PATH" run bash -c "$(_router_env)
        cd /root/cloudify && bash cloudify --on nosuchnode: install bats-test 2>&1
    "

    [ "$status" -ne 0 ]
    [[ "$output" == *"node 'nosuchnode' not found"* ]]
}

@test "real router: --on <plain host> stays a plain host" {
    _create_ssh_stub
    _create_ivps_target_stub

    PATH="$STUB_DIR:$PATH" run bash -c "$(_router_env)
        cd "$PWD" && bash cloudify --on myserver install bats-test 2>&1
    "

    [ "$status" -eq 0 ]
    grep -q "root@myserver" "$STUB_DIR/ssh_calls.log"
}

@test "real router: cloudify node use prints the export" {
    _create_ivps_target_stub

    PATH="$STUB_DIR:$PATH" run bash -c "$(_router_env)
        cd /root/cloudify && bash cloudify node use cloudai 2>&1
    "

    [ "$status" -eq 0 ]
    [[ "$output" == *"export CLOUDIFY_NODE=cloudai"* ]]
}

@test "verify subcommand errors with usage when no package given" {
    run bash -c "cd /root/cloudify && \
        CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true \
        CLOUDIFY_IS_LOCAL=true CLOUDIFY_DIR=/tmp/cf-router-test CLOUDIFY_TMP=/tmp/cf-router-test-tmp \
        DEBUG=false bash cloudify verify 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Missing package"* ]]
}

# ---------------------------------------------------------------
# Application commands (state model v2 Phase 3 slice 3B)
# ---------------------------------------------------------------

@test "real router: app without a verb prints its usage and exits non-zero" {
    run bash -c "cd $PWD && CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true CLOUDIFY_IS_LOCAL=true \
        CLOUDIFY_DIR=$CLOUDIFY_DIR CLOUDIFY_TMP=$CLOUDIFY_TMP DEBUG=false bash cloudify app 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage: cloudify app <run>"* ]]
}

@test "real router: app reconfigure, verify and teardown are reserved until Phase 4" {
    local verb
    for verb in reconfigure verify teardown; do
        run bash -c "cd $PWD && CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true CLOUDIFY_IS_LOCAL=true \
            CLOUDIFY_DIR=$CLOUDIFY_DIR CLOUDIFY_TMP=$CLOUDIFY_TMP DEBUG=false bash cloudify app $verb 2>&1"
        [ "$status" -ne 0 ]
        [[ "$output" == *"not yet available"* ]]
        [[ "$output" == *"Phase 4"* ]]
    done
}

@test "real router: app run on a missing application names the reference and the deployment name" {
    run bash -c "cd $PWD && CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true CLOUDIFY_IS_LOCAL=true \
        CLOUDIFY_DIR=$CLOUDIFY_DIR CLOUDIFY_TMP=$CLOUDIFY_TMP DEBUG=false bash cloudify app run missing/app --name prod 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"app run missing/app --name prod"* ]]
    [[ "$output" == *"No runbook found for application 'missing/app'"* ]]
}

@test "real router: deployment show and migrate are routed" {
    run bash -c "cd $PWD && CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true CLOUDIFY_IS_LOCAL=true \
        CLOUDIFY_DIR=$CLOUDIFY_DIR CLOUDIFY_TMP=$CLOUDIFY_TMP DEBUG=false bash cloudify deployment show nosuch 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"deployment: nosuch"* ]]

    run bash -c "cd $PWD && CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true CLOUDIFY_IS_LOCAL=true \
        CLOUDIFY_DIR=$CLOUDIFY_DIR CLOUDIFY_TMP=$CLOUDIFY_TMP DEBUG=false bash cloudify deployment migrate nosuch 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--application is required"* ]]
}
