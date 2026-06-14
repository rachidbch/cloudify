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

    # Package-specific vars are injected dynamically from ~/.config/cloudify/pkgs/<pkg>.yaml
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

# Collect remote var names for the given command args with recursive dependency walk.
# Usage: _cloudify_pkg_remote_vars install pkg1 pkg2  (or --install pkg1 pkg2)
#
# Algorithm:
#   1. Always-forward vars (remote-vars.yaml) loaded first — highest priority
#   2. Named packages processed right-to-left (last CLI arg wins)
#   3. For each package, recursive walk of pkg_depends lines; parent before deps
#   4. First-write-wins via temp file: once a var is claimed, descendants can't override
#   5. Cycle guard via local associative array
#
# Priority: remote-vars.yaml > rightmost-pkg > ... > leftmost-pkg > deps > deps-of-deps
#
# Side effect: exports config values into environment (first-write-wins).
# Outputs: var names, one per line (deduplicated)
function _cloudify_pkg_remote_vars() {
    # shellcheck disable=SC2206  # intentional word-splitting of $@ for "--install pkg1 pkg2"
    local args=($@)
    local config_dir="${CLOUDIFY_CREDENTIALS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/cloudify}"
    local in_install=false

    TMPFILE=$(mktemp /tmp/cloudify-pkg-vars-XXXXXX)
    trap 'rm -f "$TMPFILE"' RETURN

    # -- Helper: export vars from a yaml file, first-write-wins via temp file --
    _try_claim() {
        local yaml="$1"
        [[ -f "$yaml" ]] || return 0
        while IFS= read -r line; do
            [[ "$line" =~ ^[A-Z_][A-Z0-9_]*: ]] || continue
            local key="${line%%:*}"
            grep -qx "$key" "$TMPFILE" 2>/dev/null && continue  # already claimed
            echo "$key" >> "$TMPFILE"
            local value="${line#*:}"
            value="${value## }"; value="${value%% }"
            value="${value#\"}"; value="${value%\"}"
            value="${value#\'}"; value="${value%\'}"
            export "$key"="$value"
        done < "$yaml"
    }

    # -- Always-forward vars (highest priority) --
    local always_file="$config_dir/remote-vars.yaml"
    _cloudify_load_yaml_vars "$always_file"
    if [[ -f "$always_file" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[A-Z_][A-Z0-9_]*: ]] || continue
            echo "${line%%:*}" >> "$TMPFILE"
        done < "$always_file"
    fi

    # -- Detect install command --
    for arg in "${args[@]}"; do
        [[ "$arg" == "install" || "$arg" == "--install" ]] && { in_install=true; break; }
    done

    if $in_install; then
        # Collect named packages (args after "install" that aren't flags)
        local -a pkgs=()
        local saw_install=false
        for arg in "${args[@]}"; do
            if [[ "$arg" == "install" || "$arg" == "--install" ]]; then
                saw_install=true; continue
            fi
            $saw_install && [[ "$arg" != -* ]] && pkgs+=("$arg")
        done

        # -- Recursive walk with cycle guard --
        declare -A _visited_pkgs
        _recurse_pkg_vars() {
            local pkg="$1"
            [[ -n "${_visited_pkgs[$pkg]:-}" ]] && return 0
            _visited_pkgs[$pkg]=1

            _try_claim "$config_dir/pkgs/${pkg}.yaml"    # parent first

            local recipe deps
            recipe=$(cloudify_package_recipe_path "$pkg" 2>/dev/null) || return 0
            deps=$(grep '^[[:space:]]*pkg_depends ' "$recipe" 2>/dev/null \
                | sed 's/.*pkg_depends //' | tr ' ' '\n')
            for dep in $deps; do
                [[ -n "$dep" ]] && _recurse_pkg_vars "$dep"
            done
        }

        # Right-to-left: last CLI arg = highest priority
        for ((i = ${#pkgs[@]} - 1; i >= 0; i--)); do
            _recurse_pkg_vars "${pkgs[i]}"
        done
    fi

    sort -u "$TMPFILE" 2>/dev/null
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
        # Run in parent shell (not $()) so export calls survive for envsubst below.
        local pkg_var_names
        local _pkg_vars_list="${CLOUDIFY_TMP}/pkg-vars-list-$$"
        _cloudify_pkg_remote_vars "$@" > "$_pkg_vars_list"
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
