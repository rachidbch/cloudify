#!/usr/bin/env bash
# lib/credentials.sh - Credential management functions for cloudify
set -Eeuo pipefail
# Extracted from cloudify monolith

[[ -n "${_CLOUDIFY_CREDENTIALS_LOADED:-}" ]] && return 0
_CLOUDIFY_CREDENTIALS_LOADED=1

# Write a safe export line to credential file
# Uses single quotes to prevent shell metacharacter issues in passwords
function _cloudify_write_export() {
    local var_name="$1"
    local var_value="$2"
    printf "export %s='%s'\n" "$var_name" "${var_value//\'/\'\\\'\'}"
}

# Generic helper to ask for credentials
# Usage: _cloudify_ask_credentials <label> <user_var> <pwd_var>
function _cloudify_ask_credentials() {
    local label="$1"
    local user_var="$2"
    local pwd_var="$3"
    echo
    cloudify_prompt2var "${label} user:" "$user_var" && export "${user_var?}"
    # shellcheck disable=SC2163
    cloudify_prompt2pass "$pwd_var" && export "${pwd_var?}"
    echo
}

# Ask host credentials
function cloudify_ask_localhost_credentials() {
    _cloudify_ask_credentials "Host" "CLOUDIFY_LOCAL_USER" "CLOUDIFY_LOCAL_PWD"
}

# Ask host credentials
function cloudify_ask_host_credentials() {
    _cloudify_ask_credentials "Remote Host" "CLOUDIFY_REMOTE_USER" "CLOUDIFY_REMOTE_PWD"
}

# Ask Github credentials
function cloudify_ask_github_credentials() {
    _cloudify_ask_credentials "Github" "CLOUDIFY_GITHUBUSER" "CLOUDIFY_GITHUBPWD"
}

# Ask for Gitlab credentials
function cloudify_ask_gitlab_credentials() {
    _cloudify_ask_credentials "Gitlab" "CLOUDIFY_GITLABUSER" "CLOUDIFY_GITLABPWD"
}

# Ask Restic/Rclone credentials
function cloudify_ask_restic_credentials() {
    echo
    # Ensure Restic variables and credentials are set
    cloudify_prompt2var "Rclone Remote Name:" "CLOUDIFY_RCLONE_REMOTE" && export CLOUDIFY_RCLONE_REMOTE
    cloudify_prompt2var "Rclone Remote Region:" "CLOUDIFY_RCLONE_REMOTE_REGION" && export CLOUDIFY_RCLONE_REMOTE_REGION
    cloudify_prompt2var "Rclone Remote Endpoint:" "CLOUDIFY_RCLONE_REMOTE_ENDPOINT" && export CLOUDIFY_RCLONE_REMOTE_ENDPOINT
    cloudify_prompt2var "Rclone Remote Access Key Id:" "CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID" && export CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID
    cloudify_prompt2var "Rclone Remote Secret Access Key:" "CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY" && export CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY
    cloudify_prompt2pass "RESTIC_PASSWORD" "Restic password" && export RESTIC_PASSWORD
    echo
}

# Check if needed credentials are set in appropriate environment  variables
# If not, ask for credentials and generate a script that the user will source to set the environment variables
# =Note= Should be split!
function cloudify_check_credentials() {
    # Check for credentials environment variables
    ## sudo user and password, gitlab and github user and password must be set in env variables
    local force_ask_credentials=false
    if [[ "${1-}" == "-f" || "${1-}" == "--force" ]]; then
        force_ask_credentials=true
    fi

    local new_credentials=false

    if "$force_ask_credentials" || [[ -z "${CLOUDIFY_LOCAL_USER-}" || -z \
    "${CLOUDIFY_LOCAL_PWD-}" || -z \
    "${CLOUDIFY_REMOTE_USER-}" || -z \
    "${CLOUDIFY_REMOTE_PWD-}" || -z \
    "${CLOUDIFY_GITHUBUSER-}" || -z \
    "${CLOUDIFY_GITHUBPWD-}" || -z \
    "${CLOUDIFY_GITLABUSER-}" || -z \
    "${CLOUDIFY_GITLABPWD-}" || -z \
    "${CLOUDIFY_RCLONE_REMOTE-}" || -z \
    "${CLOUDIFY_RCLONE_REMOTE_REGION-}" || -z \
    "${CLOUDIFY_RCLONE_REMOTE_ENDPOINT-}" || -z \
    "${CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID-}" || -z \
    "${CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY-}" || -z \
    "${RESTIC_PASSWORD-}" ]]; then

        new_credentials=true
        msg "${GREEN}Cloudify needs your Host, Github and Gitlab credentials.${RESET}"
        [[ -f /dev/shm/cloudify_credentials ]] && rm -f "/dev/shm/cloudify_credentials"
        touch /dev/shm/cloudify_credentials
        chmod 600 /dev/shm/cloudify_credentials
    fi

    # If a .credentials file is found, use it
    if [[ -f ${HOME}/cloudify/.credentials ]]; then
        if [[ -f /dev/shm/cloudify_credentials ]]; then
            msg "${GREEN}Credentials read from ${HOME}/cloudify/.credentials file.${RESET}"
            cp "${HOME}/cloudify/.credentials" /dev/shm/cloudify_credentials
        else
            msg "${RED}File /dev/shm/cloudify_credentials already exist. Use 'force' option to overwrite.${RESET}"
        fi
    # If no .credentials file is found, prompt the user for credentials
    else
        # Ensure local host user is set
        if "$force_ask_credentials" || [[ -z "${CLOUDIFY_LOCAL_USER-}" || -z "${CLOUDIFY_LOCAL_PWD-}" ]]; then
            cloudify_ask_localhost_credentials
            {
                _cloudify_write_export CLOUDIFY_LOCAL_USER "$CLOUDIFY_LOCAL_USER"
                _cloudify_write_export CLOUDIFY_LOCAL_PWD "$CLOUDIFY_LOCAL_PWD"
            } >>/dev/shm/cloudify_credentials
        fi

        # Ensure remote host user is set
        if "$force_ask_credentials" || [[ -z "${CLOUDIFY_REMOTE_USER-}" || -z "${CLOUDIFY_REMOTE_PWD-}" ]]; then
            cloudify_ask_host_credentials
            {
                _cloudify_write_export CLOUDIFY_REMOTE_USER "$CLOUDIFY_REMOTE_USER"
                _cloudify_write_export CLOUDIFY_REMOTE_PWD "$CLOUDIFY_REMOTE_PWD"
            } >>/dev/shm/cloudify_credentials
        fi

        # Ensure remote Github user is set
        if "$force_ask_credentials" || [[ -z "${CLOUDIFY_GITHUBUSER-}" || -z "${CLOUDIFY_GITHUBPWD-}" ]]; then
            cloudify_ask_github_credentials
            {
                _cloudify_write_export CLOUDIFY_GITHUBUSER "$CLOUDIFY_GITHUBUSER"
                _cloudify_write_export CLOUDIFY_GITHUBPWD "$CLOUDIFY_GITHUBPWD"
            } >>/dev/shm/cloudify_credentials
        fi

        # Ensure remote Gitlab host user is set
        if "$force_ask_credentials" || [[ -z "${CLOUDIFY_GITLABUSER-}" || -z "${CLOUDIFY_GITLABPWD-}" ]]; then
            cloudify_ask_gitlab_credentials
            {
                _cloudify_write_export CLOUDIFY_GITLABUSER "$CLOUDIFY_GITLABUSER"
                _cloudify_write_export CLOUDIFY_GITLABPWD "$CLOUDIFY_GITLABPWD"
            } >>/dev/shm/cloudify_credentials
        fi

        # Ensure remote Restic/Rclone credentials are set
        if "$force_ask_credentials" || [[ -z "${CLOUDIFY_RCLONE_REMOTE-}" || -z "${CLOUDIFY_RCLONE_REMOTE_REGION-}" || -z "${CLOUDIFY_RCLONE_REMOTE_ENDPOINT-}" || -z "${CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID-}" || -z "${CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY-}" || -z "${RESTIC_PASSWORD-}" ]]; then
            cloudify_ask_restic_credentials
            {
                _cloudify_write_export CLOUDIFY_RCLONE_REMOTE "$CLOUDIFY_RCLONE_REMOTE"
                _cloudify_write_export CLOUDIFY_RCLONE_REMOTE_REGION "$CLOUDIFY_RCLONE_REMOTE_REGION"
                _cloudify_write_export CLOUDIFY_RCLONE_REMOTE_ENDPOINT "$CLOUDIFY_RCLONE_REMOTE_ENDPOINT"
                _cloudify_write_export CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID "$CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID"
                _cloudify_write_export CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY "$CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY"
                _cloudify_write_export RESTIC_PASSWORD "$RESTIC_PASSWORD"
            } >>/dev/shm/cloudify_credentials
        fi
    fi

    if "$new_credentials"; then
        echo
        msg "${GREEN}A script was generated to store these credentials in environment variables.${RESET}"
        msg "${GREEN}Please execute the following command line:${RESET}"
        msg "source /dev/shm/cloudify_credentials"
    fi
}
