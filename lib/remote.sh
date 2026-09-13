#!/usr/bin/env bash
# lib/remote.sh - Remote execution functions for cloudify
set -Eeuo pipefail
# Extracted from cloudify monolith

[[ -n "${_CLOUDIFY_REMOTE_LOADED:-}" ]] && return 0
_CLOUDIFY_REMOTE_LOADED=1

# The dispatch wrapper resolves value names through lib/context.sh. Source it
# here so any caller that has lib/remote.sh also has the resolver; the router
# sources both and the module guard makes the second load a no-op.
if [[ -z "${_CLOUDIFY_CONTEXT_LOADED:-}" ]]; then
    # shellcheck source=/dev/null
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/context.sh"
fi

#== REMOTING
##  Cloudify can execute cloudify package init scripts on remote host

# HACK! The ':' at the end of this function is there so that the '; cloudify ...' command that will be added by cloudify_remote can be on its own line.
#       Without it it was concatained to the last 'fi' line, which was ugly
# Template variables $VAR are substituted at runtime by cloudify_remote_sync via envsubst
# shellcheck disable=SC1083,SC2016
function cloudify_remote_payload_template() {
    export CLOUDIFY_IS_LOCAL=false
    export CLOUDIFY_DISABLE_COLORS='$CLOUDIFY_DISABLE_COLORS'
    export CLOUDIFY_FORCE_COLORS=true

    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a

    export CLOUDIFY_SKIPCREDENTIALS=true

    export DEBUG='$DEBUG'
    export CLOUDIFY_LOG_LEVEL='$CLOUDIFY_LOG_LEVEL'
    export CLOUDIFY_NO_DEFAULTS='$CLOUDIFY_NO_DEFAULTS'

    export CLOUDIFY_LOCAL_BIN="$HOME/.local/bin"

    export CLOUDIFY_LOCAL_USER='$CLOUDIFY_REMOTE_USER'
    export CLOUDIFY_LOCAL_PWD='$CLOUDIFY_REMOTE_PWD'
    export CLOUDIFY_HOSTPWD='$CLOUDIFY_REMOTE_PWD'

    export CLOUDIFY_GITHUBUSER='$CLOUDIFY_GITHUBUSER'
    export CLOUDIFY_GITHUBPWD='$CLOUDIFY_GITHUBPWD'
    export CLOUDIFY_GITHUB_READONLY_TOKEN='$CLOUDIFY_GITHUB_READONLY_TOKEN'
    export CLOUDIFY_GITLABUSER='$CLOUDIFY_GITLABUSER'
    export CLOUDIFY_GITLABPWD='$CLOUDIFY_GITLABPWD'

    export CLOUDIFY_RCLONE_REMOTE='$CLOUDIFY_RCLONE_REMOTE'
    export CLOUDIFY_RCLONE_REMOTE_REGION='$CLOUDIFY_RCLONE_REMOTE_REGION'
    export CLOUDIFY_RCLONE_REMOTE_ENDPOINT='$CLOUDIFY_RCLONE_REMOTE_ENDPOINT'
    export CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID='$CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID'
    export CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY='$CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY'
    export RESTIC_PASSWORD='$RESTIC_PASSWORD'

    # Package-specific vars are injected dynamically from ~/.config/cloudify/pkgs/<pkg>.yaml
    : _CLOUDIFY_PKG_EXPORTS_

    export CLOUDIFY_CLEAR_DATA='$CLOUDIFY_CLEAR_DATA'
    export CLOUDIFY_FORCE='$CLOUDIFY_FORCE'
    export CLOUDIFY_NO_VERIFY='$CLOUDIFY_NO_VERIFY'
    export PKG_VERIFY_TIMEOUT='$PKG_VERIFY_TIMEOUT'

    # shellcheck disable=SC1009,SC1054,SC1056,SC1072,SC1073,SC1083,SC2016,SC2086
    if '$CLOUDIFY_FORCE_UPDATE' || [[ -z "$(find $HOME/cloudify/.#last_update -mmin -'$CLOUDIFY_UPDATE_DELAY' 2>/dev/null)" ]]; then
        command -v git >/dev/null 2>&1 || apt-get install -y -qq git
        bash -c "$(curl -sL '$CLOUDIFY_BOOTSTRAP_URL')" </dev/null
    fi
    mkdir -p /tmp/cloudify/logs
    # Use the local log filename if passed (matching pair), otherwise generate one
    # shellcheck disable=SC2157
    if [ -n '$CLOUDIFY_LOG_BASENAME' ]; then
        CLOUDIFY_LOG_FILE="/tmp/cloudify/logs/$CLOUDIFY_LOG_BASENAME"
    else
        CLOUDIFY_LOG_FILE="/tmp/cloudify/logs/$(date +%Y%m%d-%H%M%S).log"
    fi
    export CLOUDIFY_LOG_FILE
    : > "$CLOUDIFY_LOG_FILE"
    ln -sf "$CLOUDIFY_LOG_FILE" /tmp/cloudify/logs/latest.log
    cloudify init </dev/null
    # Tee output to log + SSH channel. Do NOT detach stdin globally: the payload
    # arrives on stdin; package-code commands carry their own `</dev/null`.
    exec > >(tee -a "$CLOUDIFY_LOG_FILE") 2>&1
    :
}

# _cloudify_context_file_init - create THIS dispatch's context file and export
# CLOUDIFY_CONTEXT_FILE. The PARENT calls it before the child starts (the
# backgrounded cloudify_remote_sync, or the local install subshell) so the
# parent already knows the path for the later registry write; the child fills
# it. The path never travels as an argument, so it never enters ssh argv
# (design section 5, inv 2).
function _cloudify_context_file_init() {
    CLOUDIFY_CONTEXT_FILE=$(mktemp "$CLOUDIFY_TMP/cloudify-context-XXXXXX") \
        || die "Cannot create a dispatch context file under $CLOUDIFY_TMP."
    chmod 600 "$CLOUDIFY_CONTEXT_FILE"
    export CLOUDIFY_CONTEXT_FILE
}

# _cloudify_dispatch_vars <names-file> <action> <deployment> <phase> [pkg...]
# Resolve one dispatch's forwarded names and export their literals into the
# CALLING shell (inv 1: always invoked with a redirect, never `$(...)`), then
# write the claimed names, sorted, one per line, to <names-file>. Resolution
# itself lives in lib/context.sh; this is only the dispatch-facing wrapper.
function _cloudify_dispatch_vars() {
    local names_file="$1" action="$2" deployment="$3" phase="$4"
    shift 4
    local -a pkgs=("$@")

    if [[ -z "${CLOUDIFY_CONTEXT_FILE:-}" ]]; then
        die "_cloudify_dispatch_vars: CLOUDIFY_CONTEXT_FILE is not set."
    fi
    local cand_file
    cand_file=$(mktemp "$CLOUDIFY_TMP/cloudify-candidates-XXXXXX")
    if (( ${#pkgs[@]} )); then
        cloudify_context_candidate_names "${pkgs[@]}" > "$cand_file"
    fi
    cloudify_context_build "$action" "$deployment" "$phase" "$cand_file" \
        "${pkgs[@]}" > /dev/null
    # The context's resolved names ARE the payload's allow-list entries, and the
    # context build wrote them in the walker's sorted order.
    sed -n 's/^value\.\([^.]*\)\.source:.*$/\1/p' "$CLOUDIFY_CONTEXT_FILE" > "$names_file"
    # L12: a declared required name no source provides is warned about, never
    # fatal (same condition and content as the walker this replaces).
    local name pkg kind
    while IFS=$'\t' read -r name pkg kind; do
        [[ -n "$name" ]] || continue
        [[ "${kind:-required}" == required ]] || continue
        [[ -n "${!name:-}" ]] || log_warn "Var $name (declared in pkg $pkg .remote-vars) is unset in caller env - not forwarded."
    done < "$cand_file"
    rm -f "$cand_file"
    return 0
}

# By default cloudify_remote executes remotely
function cloudify_remote() {
    # The PARENT owns the context path: the backgrounded sync fills the file and
    # the router records the path with the dispatch metadata, so it never
    # reaches a command line (inv 2, design section 5).
    _cloudify_context_file_init
    (cloudify_remote_sync "$@") &
    _CLOUDIFY_BG_PIDS+=($!)
    _CLOUDIFY_BG_HOSTS[$!]="$1"
}

# For some sub-commands (eg. $ cloudify exec ...), we need synchronous exection
function cloudify_remote_sync() {

    local host="$1" && shift
    $CLOUDIFY_IS_LOCAL || [[ "$host" == "localhost" ]] || die "Cloudify is already running on a remote host. Can't call cloudify remotely on another host."

    if [[ "$host" == "localhost" ]]; then
        PKG_DEBUG executing cloudify "$*"
        local cloudify_remote_exit_code=0
        cloudify "$@" 2>&1 | sed "s/^/$host: /" | sed "s/^${host}: \$//" \
            | tee -a "${CLOUDIFY_LOG_FILE:-/dev/null}" >&2 \
            || cloudify_remote_exit_code=$?
        echo "$cloudify_remote_exit_code" > "$CLOUDIFY_TMP/${host}.exit"
        return "$cloudify_remote_exit_code"
    else

        # Pass local log filename basename so remote uses matching filename
        export CLOUDIFY_LOG_BASENAME
        CLOUDIFY_LOG_BASENAME="$(basename "${CLOUDIFY_LOG_FILE:-}")"

        # --- Resolve the forwarded names and their literals (one resolution) ---
        # Run in THIS shell (not $()) so the exports survive for envsubst below
        # (inv 1); only the NAMES come back, through a file.
        local pkg_var_names
        local _pkg_vars_list
        _pkg_vars_list=$(mktemp "$CLOUDIFY_TMP/pkg-vars-list-XXXXXX")
        # Parse the action and the package words exactly as the pre-Phase-2
        # walker did: `$@` word-split, the action word anywhere in the list, the
        # package words after it (flags excluded).
        # shellcheck disable=SC2206  # intentional word-splitting of $@, as before
        local -a _ctx_args=($@) _ctx_pkgs=()
        local _ctx_arg _ctx_action="" _ctx_phase="verify" _ctx_deployment=""
        for _ctx_arg in ${_ctx_args[@]+"${_ctx_args[@]}"}; do
            case "$_ctx_arg" in
                install | --install) _ctx_action=install; _ctx_phase=install; break ;;
                configure | --configure) _ctx_action=configure; _ctx_phase=install; break ;;
                uninstall | --uninstall | u) _ctx_action=uninstall; _ctx_phase=install; break ;;
            esac
        done
        _ctx_action="${_ctx_action:-${_ctx_args[0]:-verify}}"
        if [[ "$_ctx_phase" == install ]]; then
            local _ctx_saw_action=false
            for _ctx_arg in ${_ctx_args[@]+"${_ctx_args[@]}"}; do
                case "$_ctx_arg" in
                    install | --install | configure | --configure | uninstall | --uninstall | u)
                        _ctx_saw_action=true
                        continue
                        ;;
                esac
                if $_ctx_saw_action && [[ "$_ctx_arg" != -* ]]; then
                    _ctx_pkgs+=("$_ctx_arg")
                fi
            done
            _ctx_deployment="${CLOUDIFY_DEPLOYMENT:-}"
        fi
        # The parent (cloudify_remote) creates the context file so it already
        # knows the path; a direct call (cloudify exec, tests) makes its own and
        # removes it, because no parent will ever consume that metadata.
        local _ctx_own=""
        if [[ -z "${CLOUDIFY_CONTEXT_FILE:-}" ]]; then
            _cloudify_context_file_init
            _ctx_own=1
        fi
        _cloudify_dispatch_vars "$_pkg_vars_list" "$_ctx_action" "$_ctx_deployment" "$_ctx_phase" \
            "${_ctx_pkgs[@]}"
        if [[ -n "$_ctx_own" ]]; then
            # Remove the self-created context only when THIS function returns, so
            # the provenance labels are still readable for the debug rendering
            # below (the payload is already extracted by then).
            local _ctx_own_file="$CLOUDIFY_CONTEXT_FILE"
            trap '[[ "${FUNCNAME[0]:-}" == "cloudify_remote_sync" ]] && rm -f "${_ctx_own_file:-}"' RETURN
        fi
        pkg_var_names=$(cat "$_pkg_vars_list")
        rm -f "$_pkg_vars_list"
        local pkg_envsubst=""
        local pkg_exports=""
        if [[ -n "$pkg_var_names" ]]; then
            local var
            while IFS= read -r var; do
                [[ -n "$var" ]] || continue
                pkg_envsubst="$pkg_envsubst \$$var"
                pkg_exports="${pkg_exports}"$'\n'"    export $var='\$$var'"
            done <<< "$pkg_var_names"
        fi

        # Read remote payload template
        local cloudify_remote_payload
        cloudify_remote_payload=$(declare -f cloudify_remote_payload_template | tail -n +3 | head -n -1)

        # Inject package exports placeholder
        cloudify_remote_payload="${cloudify_remote_payload//_CLOUDIFY_PKG_EXPORTS_/$pkg_exports}"

        # Substitute template variables via envsubst (only listed variables are expanded)
        # shellcheck disable=SC2016
        cloudify_remote_payload=$(envsubst \
            "\$CLOUDIFY_DISABLE_COLORS \$DEBUG \$CLOUDIFY_LOG_LEVEL \$CLOUDIFY_NO_DEFAULTS \$CLOUDIFY_CLEAR_DATA \$CLOUDIFY_FORCE \$CLOUDIFY_NO_VERIFY \$PKG_VERIFY_TIMEOUT \$CLOUDIFY_FORCE_UPDATE \$CLOUDIFY_UPDATE_DELAY \$CLOUDIFY_REMOTE_USER \$CLOUDIFY_REMOTE_PWD \$CLOUDIFY_GITHUBUSER \$CLOUDIFY_GITHUBPWD \$CLOUDIFY_GITHUB_READONLY_TOKEN \$CLOUDIFY_GITLABUSER \$CLOUDIFY_GITLABPWD \$CLOUDIFY_RCLONE_REMOTE \$CLOUDIFY_RCLONE_REMOTE_REGION \$CLOUDIFY_RCLONE_REMOTE_ENDPOINT \$CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID \$CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY \$RESTIC_PASSWORD \$CLOUDIFY_BOOTSTRAP_URL \$CLOUDIFY_LOG_BASENAME${pkg_envsubst}" \
            <<< "$cloudify_remote_payload")

        # Append the command; </dev/null keeps package code off the payload's stdin.
        cloudify_remote_payload="$cloudify_remote_payload; cloudify $* </dev/null"

        # Debug renders names, source labels and redaction status only (Phase 2.3,
        # Phase 5.4): the payload text is never printed, so a secret whose name the
        # masking heuristics do not recognise cannot leak through DEBUG=true.
        if $DEBUG; then
            local _dbg_context="${CLOUDIFY_CONTEXT_FILE:-}" _dbg_name _dbg_src _dbg_sec
            msg "Payload for $host: $(printf '%s' "$pkg_var_names" | grep -c . || true) forwarded name(s)."
            while IFS= read -r _dbg_name; do
                [[ -n "$_dbg_name" ]] || continue
                _dbg_src=$(cloudify_context_read "$_dbg_context" "value.${_dbg_name}.source" 2>/dev/null || true)
                _dbg_sec=$(cloudify_context_read "$_dbg_context" "value.${_dbg_name}.secret" 2>/dev/null || true)
                msg "  $_dbg_name source=${_dbg_src:-recipe} secret=${_dbg_sec:-false} value=$( [[ "${_dbg_sec:-false}" == "true" ]] && printf 'redacted' || printf 'shown-at-recipe' )"
            done <<< "$pkg_var_names"
        fi

        PKG_DEBUG "SSHing..."
        # The SSH session is launched in the background to parallelize hosts cloudifcation
        # Known limitation: remote host key checking is disabled (StrictHostKeyChecking=no).
        # This avoids first-connection prompts but accepts a MITM risk. Future improvement:
        # pre-populate known_hosts from the inventory, or parse SSH banners to prompt the user.
        local cloudify_remote_exit_code=0
        # Payload on stdin, never argv (no secret in the process list). A 0600 file
        # redirect (not a pipe) avoids a SIGPIPE race under pipefail.
        local payload_file
        payload_file=$(mktemp "$CLOUDIFY_TMP/cloudify-payload-XXXXXX")
        chmod 600 "$payload_file"
        printf '%s\n' "$cloudify_remote_payload" > "$payload_file"
        ssh -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" -o "ConnectTimeout=10" \
            "$CLOUDIFY_REMOTE_USER@$host" 'bash -s' < "$payload_file" 2>&1 \
            | stdbuf -oL sed "s/^/$host: /" \
            | stdbuf -oL sed "s/^${host}: \$//" \
            | tee -a "${CLOUDIFY_LOG_FILE:-/dev/null}" >&2 \
            || cloudify_remote_exit_code=$?
        rm -f "$payload_file"
        echo "$cloudify_remote_exit_code" > "$CLOUDIFY_TMP/${host}.exit"
        return "$cloudify_remote_exit_code"
    fi
}
