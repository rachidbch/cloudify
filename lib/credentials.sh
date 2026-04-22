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

#== CREDENTIAL MANAGEMENT FUNCTIONS ==

# Ensure credentials directory exists with correct permissions
function cloudify_credentials_ensure_dir() {
    mkdir -p "${CLOUDIFY_CREDENTIALS_DIR:="${XDG_CONFIG_HOME:-$HOME/.config}/cloudify"}"
    chmod 700 "${CLOUDIFY_CREDENTIALS_DIR:="${XDG_CONFIG_HOME:-$HOME/.config}/cloudify"}"
}

# Save specified section's credentials to the credentials file
# Sections: remote, github, gitlab, or empty for all
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
        "")
            # All sections
            vars=(CLOUDIFY_REMOTE_USER CLOUDIFY_REMOTE_PWD CLOUDIFY_GITHUBUSER CLOUDIFY_GITHUBPWD CLOUDIFY_GITLABUSER CLOUDIFY_GITLABPWD)
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
    done < "$cred_file"
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
        "")
            cloudify_ask_host_credentials
            cloudify_credentials_save remote
            cloudify_ask_github_credentials
            cloudify_credentials_save github
            cloudify_ask_gitlab_credentials
            cloudify_credentials_save gitlab
            msg "${GREEN}All credentials saved to ${CLOUDIFY_CREDENTIALS_FILE}${RESET}"
            ;;
        *)
            die "Unknown credentials section: $section"
            ;;
    esac
}
