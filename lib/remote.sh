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
# Template placeholders {{...}} are substituted at runtime by cloudify_remote_sync
# shellcheck disable=SC1083
function cloudify_remote_payload_template() {
    export CLOUDIFY_IS_LOCAL=false
    export CLOUDIFY_DISABLE_COLORS={{CLOUDIFY_DISABLE_COLORS}}
    export CLOUDIFY_FORCE_COLORS=true

    export CLOUDIFY_SKIPCREDENTIALS=true

    export DEBUG={{DEBUG}}

    export CLOUDIFY_LOCAL_USER='{{CLOUDIFY_REMOTE_USER}}'
    export CLOUDIFY_LOCAL_PWD='{{CLOUDIFY_REMOTE_PWD}}'
    export CLOUDIFY_HOSTPWD='{{CLOUDIFY_REMOTE_PWD}}'

    export CLOUDIFY_GITHUBUSER='{{CLOUDIFY_GITHUBUSER}}'
    export CLOUDIFY_GITHUBPWD='{{CLOUDIFY_GITHUBPWD}}'
    export CLOUDIFY_GITLABUSER='{{CLOUDIFY_GITLABUSER}}'
    export CLOUDIFY_GITLABPWD='{{CLOUDIFY_GITLABPWD}}'

    export CLOUDIFY_RCLONE_REMOTE='{{CLOUDIFY_RCLONE_REMOTE}}'
    export CLOUDIFY_RCLONE_REMOTE_REGION='{{CLOUDIFY_RCLONE_REMOTE_REGION}}'
    export CLOUDIFY_RCLONE_REMOTE_ENDPOINT='{{CLOUDIFY_RCLONE_REMOTE_ENDPOINT}}'
    export CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID='{{CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID}}'
    export CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY='{{CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY}}'
    export RESTIC_PASSWORD='{{RESTIC_PASSWORD}}'

    # shellcheck disable=SC1009,SC1054,SC1056,SC1072,SC1073,SC1083
    if {{CLOUDIFY_FORCE_UPDATE}} || [[ -z "$(find $HOME/cloudify/.#last_update -mmin -{{CLOUDIFY_UPDATE_DELAY}})" ]]; then
        bash -c "$(curl -sL {{CLOUDIFY_BOOTSTRAP_URL}})"
    fi
    :
}

# By default cloudify_remote executes remotely
function cloudify_remote() {
    (cloudify_remote_sync "$@") &
}

# =TODO= Use envsubst instead of replacing env variables one by one!
# For some sub-commands (eg. $ cloudify exec ...), we need synchronous exection
function cloudify_remote_sync() {

    # When you run "cloudify host1 cmd", the command shouldn't be allowed to call "cloudify host2 cmd2"
    # =todo= Actually it's a nice feature to have as it allows bastion hosts
    #        We should be able to call 'cloudify host1 host2 host3 cmd' and have cloudify call recursively itself
    #        This requires ssh keys, user and sudo password management capability
    #        One solution would be to have these informations stored in the inventory folder, and passed recursively from one cloudify call to the next
    local host="$1" && shift
    $CLOUDIFY_IS_LOCAL || [[ "$host" == "localhost" ]] || die "Cloudify is already running on a remote host. Can't call cloudify remotely on another host."

    # =todo= Currenty credentials (ssh key, sudo user, sudo password) are limited:
    #           - The remote user is unique and given by an env variable (CLOUDIFY_REMOTE_USER)
    #           - The remote user password is unique and given by an env variable (CLOUDIFY_REMOTE_PWD)
    #           - The ssh key is the default one of the user calling cloudify  (~/.ssh/id_rsa.pub)
    #        We need  more flexibility. Each host in the inventory should have its own ssh key, user and password
    #        This is where these credentials shoud be retrieved from the inventory directory

    if [[ "$host" == "localhost" ]]; then
        PKG_DEBUG executing cloudify "$*"
        cloudify "$@" |& sed "s/^/$host: /" |& sed "s/^$host: $//"
    else

        # Read remote payload template
        local cloudify_remote_payload
        cloudify_remote_payload=$(declare -f cloudify_remote_payload_template | tail -n +3 | head -n -1)

        # Load credentials in the payload template
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_DISABLE_COLORS\}\}/$CLOUDIFY_DISABLE_COLORS}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{DEBUG\}\}/$DEBUG}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_FORCE_UPDATE\}\}/$CLOUDIFY_FORCE_UPDATE}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_UPDATE_DELAY\}\}/$CLOUDIFY_UPDATE_DELAY}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_REMOTE_USER\}\}/$CLOUDIFY_REMOTE_USER}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_REMOTE_PWD\}\}/$CLOUDIFY_REMOTE_PWD}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_GITHUBUSER\}\}/$CLOUDIFY_GITHUBUSER}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_GITHUBPWD\}\}/$CLOUDIFY_GITHUBPWD}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_GITLABUSER\}\}/$CLOUDIFY_GITLABUSER}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_GITLABPWD\}\}/$CLOUDIFY_GITLABPWD}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_RCLONE_REMOTE\}\}/$CLOUDIFY_RCLONE_REMOTE}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_RCLONE_REMOTE_REGION\}\}/$CLOUDIFY_RCLONE_REMOTE_REGION}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_RCLONE_REMOTE_ENDPOINT\}\}/$CLOUDIFY_RCLONE_REMOTE_ENDPOINT}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID\}\}/$CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY\}\}/$CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{RESTIC_PASSWORD\}\}/$RESTIC_PASSWORD}
        cloudify_remote_payload=${cloudify_remote_payload//\{\{CLOUDIFY_BOOTSTRAP_URL\}\}/$CLOUDIFY_BOOTSTRAP_URL}

        # Add actual cloudify command (plus force output colorization as cloudify won't colorize output when running
        cloudify_remote_payload="$cloudify_remote_payload; cloudify $*"

        PKG_DEBUG "Payload to execute remotely on $host:"
        # Passwords are replaved by asterisks before printing
        # HACK! Password are recognized only if env variable ends with 'PWD', contains 'PASSWORD' or contains 'SECRET'
        local cloudify_remote_payload_secure
        cloudify_remote_payload_secure="${cloudify_remote_payload//PWD=\'*\'/PWD=\'***********\'}"
        cloudify_remote_payload_secure="${cloudify_remote_payload_secure//PASSWORD*=\'*\'/PASSWORD=\'***********\'}"
        cloudify_remote_payload_secure="${cloudify_remote_payload_secure//SECRET*=\'*\'/SECRET=\'***********\'}"

        $DEBUG && msg "$cloudify_remote_payload_secure"

        PKG_DEBUG "SSHing..."
        # The SSH session is launched in the background to parallelize hosts cloudifcation
        # =TODO= Remote hosts key checking has been totally disabled.
        #        It's highly unsafe! Parse ssh messages and prompt the user for decision instead.
        ssh -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$CLOUDIFY_REMOTE_USER@$host" "$cloudify_remote_payload" |& sed "s/^/$host: /" |& sed "s/^$host: $//" |& tail -n +2
    fi
}
