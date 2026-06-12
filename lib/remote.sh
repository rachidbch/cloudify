#!/usr/bin/env bash
# lib/remote.sh - Remote execution functions for cloudify
set -Eeuo pipefail
# Extracted from cloudify monolith

[[ -n "${_CLOUDIFY_REMOTE_LOADED:-}" ]] && return 0
_CLOUDIFY_REMOTE_LOADED=1

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
    export CLOUDIFY_GITLABUSER='$CLOUDIFY_GITLABUSER'
    export CLOUDIFY_GITLABPWD='$CLOUDIFY_GITLABPWD'

    export CLOUDIFY_RCLONE_REMOTE='$CLOUDIFY_RCLONE_REMOTE'
    export CLOUDIFY_RCLONE_REMOTE_REGION='$CLOUDIFY_RCLONE_REMOTE_REGION'
    export CLOUDIFY_RCLONE_REMOTE_ENDPOINT='$CLOUDIFY_RCLONE_REMOTE_ENDPOINT'
    export CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID='$CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID'
    export CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY='$CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY'
    export RESTIC_PASSWORD='$RESTIC_PASSWORD'

    # Package-specific vars are injected dynamically from pkg/<name>/remote-vars.yaml
    : _CLOUDIFY_PKG_EXPORTS_

    export CLOUDIFY_CLEAR_DATA='$CLOUDIFY_CLEAR_DATA'
    export CLOUDIFY_FORCE='$CLOUDIFY_FORCE'

    # shellcheck disable=SC1009,SC1054,SC1056,SC1072,SC1073,SC1083,SC2016,SC2086
    if '$CLOUDIFY_FORCE_UPDATE' || [[ -z "$(find $HOME/cloudify/.#last_update -mmin -'$CLOUDIFY_UPDATE_DELAY' 2>/dev/null)" ]]; then
        command -v git >/dev/null 2>&1 || apt-get install -y -qq git
        bash -c "$(curl -sL '$CLOUDIFY_BOOTSTRAP_URL')"
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
    cloudify init
    # Tee output to both log file and SSH channel (process substitution).
    # This makes remote install output visible on local terminal in real-time AND
    # persisted to the log file. The original hang was caused by `cat -` blocking on
    # stdin, not by process substitution. Now that </dev/null is in place, this is safe.
    # After exec, pipelines within package recipes still work — `|` creates its own fd
    # independent of the process's inherited stdin.
    exec > >(tee -a "$CLOUDIFY_LOG_FILE") 2>&1 </dev/null
    :
}

# Load package-specific config and collect remote var names for the given command args.
# Usage: _cloudify_pkg_remote_vars install pkg1 pkg2  (or --install pkg1 pkg2)
# Side effect: loads values from ~/.config/cloudify/pkgs/<pkg>.yaml into environment.
# Outputs: var names, one per line (deduplicated)
#
# Note: uses unquoted $@ to handle the case where the main parser passes
# "--install pkg1 pkg2" as a single string (word-splitting separates them).
function _cloudify_pkg_remote_vars() {
    local args=($@)
    local config_dir="${CLOUDIFY_CREDENTIALS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/cloudify}"
    local -a var_names=()
    local in_install=false

    # Always-forward vars (loaded + collected from ~/.config/cloudify/remote-vars.yaml)
    local always_file="$config_dir/remote-vars.yaml"
    _cloudify_load_yaml_vars "$always_file"
    if [[ -f "$always_file" ]]; then
        while IFS= read -r v; do
            [[ -n "$v" ]] && var_names+=("$v")
        done < <(grep -E '^[A-Z_][A-Z0-9_]*:' "$always_file" | sed 's/:.*//')
    fi

    for arg in "${args[@]}"; do
        if [[ "$arg" == "install" || "$arg" == "--install" ]]; then
            in_install=true
            continue
        fi
        if $in_install && [[ "$arg" != -* ]]; then
            # Load user config for this package (~/.config/cloudify/pkgs/<pkg>.yaml)
            _cloudify_load_yaml_vars "$config_dir/pkgs/${arg}.yaml"

            # Collect required var names from repo yaml (pkg/<name>/remote-vars.yaml)
            local repo_yaml="$CLOUDIFY_DIR/pkg/$arg/remote-vars.yaml"
            if [[ -f "$repo_yaml" ]]; then
                while IFS= read -r v; do
                    [[ -n "$v" ]] && var_names+=("$v")
                done < <(grep -E '^[A-Z_][A-Z0-9_]*:' "$repo_yaml" | sed 's/:.*//')
            fi
        fi
    done

    # Deduplicate and output
    printf '%s\n' "${var_names[@]}" | sort -u | sed '/^$/d'
}

# By default cloudify_remote executes remotely
function cloudify_remote() {
    (cloudify_remote_sync "$@") &
    _CLOUDIFY_BG_PIDS+=($!)
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

        # --- Collect package remote vars from yaml files ---
        local pkg_var_names
        pkg_var_names=$(_cloudify_pkg_remote_vars "$@")
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
            "\$CLOUDIFY_DISABLE_COLORS \$DEBUG \$CLOUDIFY_LOG_LEVEL \$CLOUDIFY_NO_DEFAULTS \$CLOUDIFY_CLEAR_DATA \$CLOUDIFY_FORCE \$CLOUDIFY_FORCE_UPDATE \$CLOUDIFY_UPDATE_DELAY \$CLOUDIFY_REMOTE_USER \$CLOUDIFY_REMOTE_PWD \$CLOUDIFY_GITHUBUSER \$CLOUDIFY_GITHUBPWD \$CLOUDIFY_GITLABUSER \$CLOUDIFY_GITLABPWD \$CLOUDIFY_RCLONE_REMOTE \$CLOUDIFY_RCLONE_REMOTE_REGION \$CLOUDIFY_RCLONE_REMOTE_ENDPOINT \$CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID \$CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY \$RESTIC_PASSWORD \$CLOUDIFY_BOOTSTRAP_URL \$CLOUDIFY_LOG_BASENAME${pkg_envsubst}" \
            <<< "$cloudify_remote_payload")

        # Add actual cloudify command (plus force output colorization as cloudify won't colorize output when running
        cloudify_remote_payload="$cloudify_remote_payload; cloudify $*"

        PKG_DEBUG "Payload to execute remotely on $host:"
        # Passwords are replaced by asterisks before printing
        # HACK! Passwords are recognized only if env variable ends with 'PWD', contains 'PASSWORD' or contains 'SECRET'
        local cloudify_remote_payload_secure
        cloudify_remote_payload_secure="${cloudify_remote_payload//PWD=\'*\'/PWD=\'***********\'}"
        cloudify_remote_payload_secure="${cloudify_remote_payload_secure//PASSWORD*=\'*\'/PASSWORD=\'***********\'}"
        cloudify_remote_payload_secure="${cloudify_remote_payload_secure//SECRET*=\'*\'/SECRET=\'***********\'}"

        $DEBUG && msg "$cloudify_remote_payload_secure"

        PKG_DEBUG "SSHing..."
        # The SSH session is launched in the background to parallelize hosts cloudifcation
        # Known limitation: remote host key checking is disabled (StrictHostKeyChecking=no).
        # This avoids first-connection prompts but accepts a MITM risk. Future improvement:
        # pre-populate known_hosts from the inventory, or parse SSH banners to prompt the user.
        local cloudify_remote_exit_code=0
        ssh -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" -o "ConnectTimeout=10" \
            "$CLOUDIFY_REMOTE_USER@$host" "$cloudify_remote_payload" 2>&1 \
            | stdbuf -oL sed "s/^/$host: /" \
            | stdbuf -oL sed "s/^${host}: \$//" \
            | tee -a "${CLOUDIFY_LOG_FILE:-/dev/null}" >&2 \
            || cloudify_remote_exit_code=$?
        echo "$cloudify_remote_exit_code" > "$CLOUDIFY_TMP/${host}.exit"
        return "$cloudify_remote_exit_code"
    fi
}
