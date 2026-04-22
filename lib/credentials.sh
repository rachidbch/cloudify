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

#== NEW CREDENTIAL MANAGEMENT FUNCTIONS ==

# Ensure credentials directory exists with correct permissions
function cloudify_credentials_ensure_dir() {
    mkdir -p "${CLOUDIFY_CREDENTIALS_DIR:="${XDG_CONFIG_HOME:-$HOME/.config}/cloudify"}"
    chmod 700 "${CLOUDIFY_CREDENTIALS_DIR:="${XDG_CONFIG_HOME:-$HOME/.config}/cloudify"}"
}

# Save specified section's credentials to the credentials file
# Sections: remote, github, gitlab, restic, or empty for all
function cloudify_credentials_save() {
    local section="${1:-}"
    local cred_file="${CLOUDIFY_CREDENTIALS_FILE:-"${XDG_CONFIG_HOME:-$HOME/.config}/cloudify/credentials"}"

    cloudify_credentials_ensure_dir

    # Define which variables belong to each section
    local -a vars=()
    case "$section" in
        remote)
            vars=(CLOUDIFY_REMOTE_USER CLOUDIFY_REMOTE_PWD)
            ;;
        github)
            vars=(CLOUDIFY_GITHUBUSER CLOUDIFY_GITHUBPWD)
            ;;
        gitlab)
            vars=(CLOUDIFY_GITLABUSER CLOUDIFY_GITLABPWD)
            ;;
        restic)
            vars=(CLOUDIFY_RCLONE_REMOTE CLOUDIFY_RCLONE_REMOTE_REGION CLOUDIFY_RCLONE_REMOTE_ENDPOINT CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY RESTIC_PASSWORD)
            ;;
        "")
            # All sections
            vars=(CLOUDIFY_REMOTE_USER CLOUDIFY_REMOTE_PWD CLOUDIFY_GITHUBUSER CLOUDIFY_GITHUBPWD CLOUDIFY_GITLABUSER CLOUDIFY_GITLABPWD CLOUDIFY_RCLONE_REMOTE CLOUDIFY_RCLONE_REMOTE_REGION CLOUDIFY_RCLONE_REMOTE_ENDPOINT CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY RESTIC_PASSWORD)
            ;;
        *)
            die "Unknown credentials section: $section"
            ;;
    esac

    # Remove existing lines for these vars from the file (if it exists)
    if [[ -f "$cred_file" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        for var in "${vars[@]}"; do
            grep -v "^export ${var}=" "$cred_file" > "$tmp_file" 2>/dev/null || true
            mv "$tmp_file" "$cred_file"
        done
    fi

    # Append new values
    for var in "${vars[@]}"; do
        local val="${!var:-}"
        if [[ -n "$val" ]]; then
            _cloudify_write_export "$var" "$val" >> "$cred_file"
        fi
    done

    chmod 600 "$cred_file"
}

# Load credentials from XDG config file if it exists
# Does NOT overwrite vars already set in environment
function cloudify_credentials_load() {
    local cred_file="${CLOUDIFY_CREDENTIALS_FILE:-"${XDG_CONFIG_HOME:-$HOME/.config}/cloudify/credentials"}"
    [[ -f "$cred_file" ]] || return 0

    # Read each line and export only vars not already set
    while IFS= read -r line; do
        # Extract variable name from "export VARNAME='value'"
        [[ "$line" =~ ^export\ ([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        local var_name="${BASH_REMATCH[1]}"
        # Skip if already set in environment
        if [[ -n "${!var_name+_}" ]]; then
            continue
        fi
        eval "$line"
        export "$var_name"
    done < "$cred_file"
}

# One-time migration from legacy credential locations
# No-op if new file already exists
function cloudify_credentials_migrate() {
    local cred_file="${CLOUDIFY_CREDENTIALS_FILE:-"${XDG_CONFIG_HOME:-$HOME/.config}/cloudify/credentials"}"
    local cred_dir
    cred_dir=$(dirname "$cred_file")

    # Already migrated
    [[ -f "$cred_file" ]] && return 0

    # Try ~/cloudify/.credentials first
    if [[ -f "${HOME}/cloudify/.credentials" ]]; then
        mkdir -p "$cred_dir"
        cp "${HOME}/cloudify/.credentials" "$cred_file"
        chmod 600 "$cred_file"
        msg "${GREEN}Credentials migrated from ${HOME}/cloudify/.credentials to $cred_file${RESET}"
        return 0
    fi

    # Try /dev/shm/cloudify_credentials as fallback
    if [[ -f /dev/shm/cloudify_credentials ]]; then
        mkdir -p "$cred_dir"
        cp /dev/shm/cloudify_credentials "$cred_file"
        chmod 600 "$cred_file"
        msg "${GREEN}Credentials migrated from /dev/shm/cloudify_credentials to $cred_file${RESET}"
        return 0
    fi
}

# Print status of each credential section
function cloudify_credentials_check() {
    local all_ok=true

    # Remote
    if [[ -n "${CLOUDIFY_REMOTE_USER:-}" && -n "${CLOUDIFY_REMOTE_PWD:-}" ]]; then
        msg "${GREEN}remote:  OK${RESET}"
    else
        msg "${YELLOW}remote:  INCOMPLETE (CLOUDIFY_REMOTE_USER, CLOUDIFY_REMOTE_PWD)${RESET}"
        all_ok=false
    fi

    # GitHub
    if [[ -n "${CLOUDIFY_GITHUBUSER:-}" && -n "${CLOUDIFY_GITHUBPWD:-}" ]]; then
        msg "${GREEN}github:  OK${RESET}"
    else
        msg "${YELLOW}github:  INCOMPLETE (CLOUDIFY_GITHUBUSER, CLOUDIFY_GITHUBPWD)${RESET}"
        all_ok=false
    fi

    # GitLab
    if [[ -n "${CLOUDIFY_GITLABUSER:-}" && -n "${CLOUDIFY_GITLABPWD:-}" ]]; then
        msg "${GREEN}gitlab:  OK${RESET}"
    else
        msg "${YELLOW}gitlab:  INCOMPLETE (CLOUDIFY_GITLABUSER, CLOUDIFY_GITLABPWD)${RESET}"
        all_ok=false
    fi

    # Restic
    if [[ -n "${CLOUDIFY_RCLONE_REMOTE:-}" && -n "${CLOUDIFY_RCLONE_REMOTE_REGION:-}" && -n "${CLOUDIFY_RCLONE_REMOTE_ENDPOINT:-}" && -n "${CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID:-}" && -n "${CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY:-}" && -n "${RESTIC_PASSWORD:-}" ]]; then
        msg "${GREEN}restic:  OK${RESET}"
    else
        msg "${YELLOW}restic:  INCOMPLETE (CLOUDIFY_RCLONE_*, RESTIC_PASSWORD)${RESET}"
        all_ok=false
    fi

    $all_ok
}

# Interactive prompt + save for specified section or all
function cloudify_credentials_setup() {
    local section="${1:-}"

    case "$section" in
        remote)
            cloudify_ask_host_credentials
            cloudify_credentials_save remote
            msg "${GREEN}Remote credentials saved.${RESET}"
            ;;
        github)
            cloudify_ask_github_credentials
            cloudify_credentials_save github
            msg "${GREEN}GitHub credentials saved.${RESET}"
            ;;
        gitlab)
            cloudify_ask_gitlab_credentials
            cloudify_credentials_save gitlab
            msg "${GREEN}GitLab credentials saved.${RESET}"
            ;;
        restic)
            cloudify_ask_restic_credentials
            cloudify_credentials_save restic
            msg "${GREEN}Restic credentials saved.${RESET}"
            ;;
        "")
            cloudify_ask_host_credentials
            cloudify_credentials_save remote
            cloudify_ask_github_credentials
            cloudify_credentials_save github
            cloudify_ask_gitlab_credentials
            cloudify_credentials_save gitlab
            cloudify_ask_restic_credentials
            cloudify_credentials_save restic
            msg "${GREEN}All credentials saved to ${CLOUDIFY_CREDENTIALS_FILE}${RESET}"
            ;;
        *)
            die "Unknown credentials section: $section"
            ;;
    esac
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
            _cloudify_ask_credentials "Host" "CLOUDIFY_LOCAL_USER" "CLOUDIFY_LOCAL_PWD"
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
