#!/usr/bin/env bash
# lib/shadows/sudo.sh - Shadow function for sudo (password injection)
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_SHADOW_SUDO_LOADED:-}" ]] && return 0
_CLOUDIFY_SHADOW_SUDO_LOADED=1

## Sudo Shadowing
#  To call commands requiring password based authentication, we generally supply the password (that is stored in CLOUDIFY_REMOTE_PWD or CLOUDIFY_LOCAL_PWD variable)
#  using a Here String (which uses stdin). Sudo command stdin is often used for normal command processing (like in 'echo <commands> | sudo tee ...')
#  So to suppy the password to sudo we need to rearrange the way sudo is called, passing everything as arguments to free stdin for password
function sudo() {
    local lineargs=""
    local pipeargs=""

    cloudify_get_password password user host
    # shellcheck disable=SC2154
    [[ -z ${password} ]] && die "Password not set for user $user on host $host."

    # Some commands arguments must be dealt with caution
    case "$1" in
    "add-apt-repository")
        # In add-apt-repository the repository line must be enclosed in single quotes or add-apt-repository complains w/ "Error: need a single repository as argument"
        lineargs="$1 '${*:2}'"
        ;;
    "sed")
        # In a sed command, the sed expression argument must be surrounded with single quotes
        local sedcmd="sed"
        local arg=""
        local arg_expr=""
        local arg_file=""
        shift
        arg="$1"
        while [[ -n "$arg" ]]; do
            if [[ "$arg" == -* ]]; then
                sedcmd="$sedcmd $arg"
            else
                if [[ -z "$arg_expr" ]]; then
                    arg_expr="$arg"
                    sedcmd="$sedcmd '$arg_expr'"
                else
                    arg_file="$arg"
                    sedcmd="$sedcmd $arg_file"
                fi
            fi
            shift
            arg="$1"
        done
        lineargs="$sedcmd"
        ;;
    "find")
        # In find command, the last ';' argument must be escaped or it will be interpreted out by the shell
        local findcmd="find"
        shift
        arg="$1"
        echo dealing with find
        while [[ -n "$arg" ]]; do
            if [[ "$arg" == ";" ]]; then
                findcmd="$findcmd \\$arg"
            else
                findcmd="$findcmd $arg"
            fi
            shift
            arg="$1"
        done
        lineargs="$findcmd"
        ;;
    *)
        lineargs="${*}"
        ;;
    esac

    # Find out if the sudo command have been called within a pipe, with arguments or both
    # This if incantation can of course be simplified but I prefer to let it that way to make the different cases clear
    if [ -t 0 ]; then
        # 'sudo' not called in a pipe
        : # Do nothing
        #lineargs="$lineargs"
    elif [[ -p /dev/stdin ]]; then
        # 'sudo' called in a pipe.
        pipeargs="$(cat -)"
    else
        # 'sudo' called with a here doc
        pipeargs="$(cat -)"
    fi

    local sudocmd=""
    if [[ -z $pipeargs ]]; then
        sudocmd="$lineargs"
    else
        sudocmd="echo '$pipeargs' | $lineargs"
    fi

    # As we pass everything, including piped input as arguments to 'bash -c', we can safely supply sudo password using a herestring
    local sudocmd_length
    sudocmd_length=$(echo -n "'$sudocmd'" | wc -m)

    if ((sudocmd_length < 10000)); then
        PKG_DEBUG command sudo -kS bash -c "$sudocmd" \<\<\< "$password"
        #command sudo -kS -p ""  bash -c "$sudocmd" 2>/dev/null <<< "$password"
        command sudo -kS -p "" bash -c "$sudocmd" <<<"$password"
    else
        # The sudo command is much too long, create a temporary file and execute it
        local tfile
        tfile=$(mktemp /tmp/foo.XXXXXXXXX)
        echo creating "$tfile"
        echo "$pipeargs" >"$tfile"
        PKG_DEBUG command sudo -kS "$lineargs" "$tfile" \<\<\< "$password"
        command sudo -p " " -kS "$lineargs" "$tfile" <<<"$password"
    fi
}
