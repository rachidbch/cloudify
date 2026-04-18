#!/usr/bin/env bash
# lib/utils.sh - General utility functions for cloudify
set -Eeuo pipefail
# Extracted from cloudify monolith

[[ -n "${_CLOUDIFY_UTILS_LOADED:-}" ]] && return 0
_CLOUDIFY_UTILS_LOADED=1

#== CLEANUP BEFORE EXIT
# Call clean up function before exiting script
# Note: trap is set in the main script
function cleanup() {
    trap - SIGINT SIGTERM ERR EXIT

    # Script cleanup here
    $DEBUG || rm -rf "${CLOUDIFY_TMP}"
}

#== GENERAL UTILITIES

# Print messages with colors
# msg sends its output to stderr (See 12 Factors CLI app principles) and support special color codes
function msg() {
    if [[ "${1-}" == "-n" ]]; then
        shift
        echo >&2 -n -e "$@"
    else
        echo >&2 -e "$@"
    fi
}

# Same as 'msg' but adds an empty line
function msg_ln() {
    echo >&2 && msg "$@"
}

# Die gracefully
function die() {
    local die_msg="$1"
    local code=${2-1} # default exit status 1
    msg "${RED}$die_msg${RESET}"
    exit "$code"
}

# Utility function to test if a directory is empty
function cloudify_emptydir() {
    local _entry
    for _entry in "$1"/*; do
        [[ -e "$_entry" ]] && return 1
    done
    return 0
}

# Utility function to test if a list contains a string
function cloudify_list_contains() {
    local aList="$1"
    local anItem="$2"
    [[ "$aList" == *"$anItem"* ]]
}

# Simply prompt the user and read the stores answer in specified variable
function cloudify_prompt2var() {
    local prompt="$1"
    local answervar="$2"
    msg -n "${GREEN}${prompt}${RESET} "
    read -r "${answervar?}"
}

# Prompt the user for a password
function cloudify_prompt2pass() {
    local answervar="$1"
    # This utility script reads the password in PWORD
    local answer
    answer=$("$CLOUDIFY_LOCAL_BIN"/askpass_stars.sh "${2:-}")
    export "$answervar"="$answer"
}

# Parse git urls
function cloudify_parse_git_url() {
    # get protocol
    [[ -n "${1-}" ]] || return 1

    local proto
    proto="$(echo "$1" | grep :// | sed -e's,^\(.*://\).*,\1,g')"
    [[ -z "${proto-}" || "${proto-}" == *:// ]] || return 1

    # remove the protocol
    local url="${1/$proto/}"
    [[ -n "${url-}" ]] || return 1

    # extract the user (if any)
    local userpass
    userpass="$(echo "$url" | grep @ | cut -d@ -f1)" || true
    local pass
    pass="$(echo "$userpass" | grep : | cut -s -d: -f2)" || true
    local user
    if [ -n "$pass" ]; then
        user="$(echo "$userpass" | grep : | cut -d: -f1)" || true
    else
        user=$userpass
    fi

    # remove the user and password
    url="${url/$userpass@/}"
    [[ -n "${url-}" ]] || return 1

    # extract the host and port
    local host_port
    host_port="$(echo "${url}" | cut -d/ -f1)"
    [[ -n "${host_port-}" ]] || return 1

    local port
    port="$(echo "${host_port}" | cut -s -d: -f2)"

    local host
    if [[ ${host_port-} == *:* && ! ${port-} =~ ^[0-9]+$ ]]; then
        [[ -z "${proto-}" ]] && proto="git://"
        host_port="$(echo "${url}" | cut -d: -f1)"
        [[ -n "${host_port-}" ]] || return 1
        port=""
        host=$host_port
    else
        [[ -z "${proto-}" ]] && proto="https://"
        host="$(echo "${host_port}" | cut -d: -f1)"
        [[ -n "${host-}" ]] || return 1
    fi

    # extract the path (if any)
    local path
    path="${url#"$host_port"}"
    path="${path#:}"

    # extract domain and subdomain
    local levels
    levels=$(echo "$host" | grep -o "\." | wc -l)
    local domain=""
    local subdomain=""
    if [ "$levels" -eq "1" ]; then
        domain=$host
    fi
    if [ "$levels" -eq "2" ]; then
        domain=$(echo "$host" | awk -F"." '{print $2 "." $3}')
        subdomain=$(echo "$host" | awk -F"." '{print $1}')
    fi
    [[ -n "${domain-}" ]] || return 1

    # extract account and project
    local account
    local project

    if [[ "$path" == /* ]]; then
        account=$(echo "$path" | cut -s -d/ -f2)
        project=$(echo "$path" | cut -s -d/ -f3)
    else
        account=$(echo "$path" | cut -d/ -f1)
        project=$(echo "$path" | cut -s -d/ -f2)
    fi

    if [[ -z "${2-}" ]]; then
        echo -e "url: $url\nproto: $proto\nuser: $user\npass: $pass\nhost_port: $host_port\nhost: $host\ndomain: $domain\nsubdomain: $subdomain\nport: $port\npath: $path\naccount: $account\nproject: $project"
    else
        for f in ${2//,/ }; do
            case $f in
            url)
                echo "$url"
                ;;
            proto)
                echo "$proto"
                ;;
            user)
                echo "$user"
                ;;
            pass)
                echo "$pass"
                ;;
            host)
                echo "$host"
                ;;
            domain)
                echo "$domain"
                ;;
            subdomain)
                echo "$subdomain"
                ;;
            port)
                echo "$port"
                ;;
            path)
                echo "$path"
                ;;
            account)
                echo "$account"
                ;;
            project)
                echo "$project"
                ;;
            esac
        done
    fi
}

# Is an url a git url ?
function cloudify_is_git_url() {
    cloudify_parse_git_url "$1" &>/dev/null
}

# Get user and password of running cloudify
function cloudify_get_password() {
    local pwd_var_name="${1:-}"
    local user_var_name="${2:-}"
    local host_var_name="${3:-}"

    [[ -z $pwd_var_name ]] && die "cloudify_get_password function called with no argument"
    [[ $pwd_var_name == *\ * ]] && die "cloudify_get_password function called with argument containing a space"
    # Use printf -v to set variables in caller's scope (declare is local to function)
    printf -v "$pwd_var_name" '%s' "$CLOUDIFY_HOSTPWD"
    [[ -z "$user_var_name" ]] || printf -v "$user_var_name" '%s' "$(whoami)"
    [[ -z "$host_var_name" ]] || printf -v "$host_var_name" '%s' "$(hostname)"
}

# Escape special characters for use in sed patterns
# Handles: / * - ! = : [ ] ( ) & \
function _cloudify_sed_escape() {
    local input="${1:-}"
    # Escape backslash first (to avoid double-escaping), then all other specials
    input="${input//\\/\\\\}"
    input="${input//\//\\/}"
    input="${input//\*/\\*}"
    input="${input//\-/\\-}"
    input="${input//\!/\\!}"
    input="${input//\=/\\=}"
    input="${input//\:/\\:}"
    input="${input//\[/\\[}"
    input="${input//\]/\\]}"
    input="${input//\(/\\(}"
    input="${input//\)/\\)}"
    input="${input//\&/\\&}"
    echo "$input"
}

# Write entries in /etc/hosts
function cloudify_add_in_hosts() {
    $DEBUG && PKG_PAUSE "About to execute: cloudify_add_in_hosts"

    cloudify_get_password password user host
    [[ -z ${password} ]] && die "Password not set for user $user on host $host."

    # sed special characters have to be escaped
    local escaped_host_lines=()
    for host_line in "${@}"; do
        PKG_DEBUG "Adding '$host_line'"
        host_line=$(_cloudify_sed_escape "$host_line")
        escaped_host_lines+=("$host_line")
    done

    PKG_DEBUG_LN "ENV TO SETUP:"
    for host_line in "${escaped_host_lines[@]}"; do
        PKG_DEBUG "About to insert: '$host_line'"
    done

    # Reserve cloudify space in /etc/hosts
    PKG_DEBUG_LN "Reserve cloudify space inside /etc/hosts"
    grep -qFx "# CLOUDIFY HOSTS START" /etc/hosts || command sudo -kS -p '' sed -i -e '$a\\n# CLOUDIFY HOSTS START\n# CLOUDIFY HOSTS END' /etc/hosts <<<"$password"

    # Insert new hosts lines
    PKG_DEBUG_LN "Inserting host lines"
    for host_line in "${escaped_host_lines[@]}"; do
        PKG_DEBUG "Inserting: $host_line"
        command sudo -kSp '' sed -i -e "/# CLOUDIFY HOSTS END/i $host_line" /etc/hosts &>/dev/null <<<"$password"
        PKG_DEBUG "Inserted: $host_line"
    done
}

# Farewell message when exiting without error
function cloudify_print_done() {
    msg "${GREEN}\n********************************************************************************${RESET}"
    msg "${GREEN}  Now please Source ~/.bashrc (Or call rcreload is alias is set)${RESET}"
    msg "${GREEN}********************************************************************************${RESET}"
    msg "${GREEN}  Station cloudified!${RESET}"
    msg "${GREEN}********************************************************************************${RESET}"
}

# Alias: legacy name kept for backwards compatibility
function add_in_hosts() {
    cloudify_add_in_hosts "$@"
}
