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

    # shellcheck disable=SC1009,SC1054,SC1056,SC1072,SC1073,SC1083,SC2016,SC2086
    if '$CLOUDIFY_FORCE_UPDATE' || [[ -z "$(find $HOME/cloudify/.#last_update -mmin -'$CLOUDIFY_UPDATE_DELAY')" ]]; then
        command -v git >/dev/null 2>&1 || apt-get install -y -qq git
        bash -c "$(curl -sL '$CLOUDIFY_BOOTSTRAP_URL')"
    fi
    :
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

        # Read remote payload template
        local cloudify_remote_payload
        cloudify_remote_payload=$(declare -f cloudify_remote_payload_template | tail -n +3 | head -n -1)

        # Substitute template variables via envsubst (only listed variables are expanded)
        # shellcheck disable=SC2016
        cloudify_remote_payload=$(envsubst \
            '$CLOUDIFY_DISABLE_COLORS $DEBUG $CLOUDIFY_FORCE_UPDATE $CLOUDIFY_UPDATE_DELAY $CLOUDIFY_REMOTE_USER $CLOUDIFY_REMOTE_PWD $CLOUDIFY_GITHUBUSER $CLOUDIFY_GITHUBPWD $CLOUDIFY_GITLABUSER $CLOUDIFY_GITLABPWD $CLOUDIFY_RCLONE_REMOTE $CLOUDIFY_RCLONE_REMOTE_REGION $CLOUDIFY_RCLONE_REMOTE_ENDPOINT $CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID $CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY $RESTIC_PASSWORD $CLOUDIFY_BOOTSTRAP_URL' \
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
            | sed "s/^/$host: /" \
            | sed "s/^${host}: \$//" \
            | tail -n +2 \
            | tee -a "${CLOUDIFY_LOG_FILE:-/dev/null}" >&2 \
            || cloudify_remote_exit_code=$?
        echo "$cloudify_remote_exit_code" > "$CLOUDIFY_TMP/${host}.exit"
        return "$cloudify_remote_exit_code"
    fi
}
