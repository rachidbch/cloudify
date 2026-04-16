#!/usr/bin/env bash
# lib/hosts.sh - Host inventory functions for cloudify
set -Eeuo pipefail
# Extracted from cloudify monolith

[[ -n "${_CLOUDIFY_HOSTS_LOADED:-}" ]] && return 0
_CLOUDIFY_HOSTS_LOADED=1

# Is a host declared in host inventory?
# Usage:
#   cloudify_is_host_in_inventory host            Test if host is declared in the inventory
# =Note= Function allowed to run locally only
function cloudify_is_host_in_inventory() {
    ! $CLOUDIFY_IS_LOCAL && die "Error: Operation \"cloudify_is_host_in_inventory\" not allowed on remote hosts." 1
    [[ $# == 0 ]] && msg "${RED}Error: Missing argument in \"cloudify_is_host_in_inventory\" call.${RESET}" && return 1

    local host="$1"
    find "$CLOUDIFY_DIR"/inventory/"$host" -maxdepth 0 -exec basename {} \; 2>/dev/null || true
}

# List packages tags
# Usage: cloudify_list_hosts_tags              List all host tags (Adding '@default' and '@all')
function cloudify_list_hosts_tags() {
    ! $CLOUDIFY_IS_LOCAL && die "Error: Can't list hosts Tags on remote hosts." 1
    find "$CLOUDIFY_DIR"/inventory -mindepth 2 -maxdepth 2 -name '@*' -exec basename {} \; | awk '!a[$0]++'
    echo @default
    echo @all
}

# Show hosts inventory filtered by tags
# Usage: cloudify_list_hosts_by_tags                           List all hosts
#        cloudify_list_hosts_by_tags --tags                    List all hosts tags
#        cloudify_list_hosts_by_tags [tag..]                   List all hosts having all tags given
# =Note= Function allowed to run locally only
# =Todo=
#        - If '@all' list all tags
function cloudify_list_hosts_by_tags() {

    # Function allowed to run locally only
    ! $CLOUDIFY_IS_LOCAL && die "Error: Operation \"cloudify_list_hosts_by_tags\" not allowed on remote hosts." 1

    # The awk incantation is here to remove dubplicates while conserving order
    {
        local current_hosts_list
        local hosts_list=""
        local filter

        # Without tag filter, return all hosts
        # Remove hosts duplicates while retaining hosts order (see awk incantation below)
        [[ $# == 0 ]] && hosts_list=$(find "$CLOUDIFY_DIR"/inventory -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | tr '\n' ' ')

        # If multiple tags are given, list the hosts that have all of them
        for filter in "$@"; do
            if ! [[ "$filter" == \@* ]]; then
                # This isn't a tag. Do nothing.
                :
            else
                # This the tag is '@all', list all hosts
                if [[ $filter == @all ]]; then
                    current_hosts_list=$(find "$CLOUDIFY_DIR"/inventory -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | tr '\n' ' ')
                else
                    # Otherwise, filter by current tag
                    current_hosts_list=$(find "$CLOUDIFY_DIR"/inventory -mindepth 2 -maxdepth 2 -name "$filter" -exec dirname {} \; -exec basename {} \; | head -1)
                    current_hosts_list=$(find "$CLOUDIFY_DIR"/inventory -mindepth 2 -maxdepth 2 -name "$filter" | while read -r d; do basename "$(dirname "$d")"; done | tr '\n' ' ')
                fi

                if [[ -z $hosts_list ]]; then
                    hosts_list=$current_hosts_list
                else
                    # 'comm' is a standard linux utility that compares FILES line by line
                    # It is used here to find the intersection of 2 LISTS
                    # The 'echo ... | tr ...' is here to transform lists in simili-files that can be fed to comm command
                    hosts_list=$(comm -12 <(echo "$hosts_list" | tr ' ' '\n') <(echo "$current_hosts_list" | tr ' ' '\n'))
                fi
            fi
        done
        echo "$hosts_list"
    } | awk '!a[$0]++'
}

# Get hosts informations
# Usage:
#   cloudify_info -h|--help                       Print help
#   cloudify_info host ipv4                       Print host ipv4
#   cloudify_info host ipv6                       Print host ipv6
# =Note=
#   LXC doesn't make it easy to get specific info on containers.
#   But as it provides info in json format, 'cloudify info' can parse it with jq to extract specific bits of information
#  The command `cloudify info proxy IPV4` (resp. `cloudify info proxy IPV4`) return the IPV4 address (resp. IPV6 address) of 'proxy' host
function cloudify_info() {
    # Function allowed to run locally only
    ! $CLOUDIFY_IS_LOCAL && die "Error: Operation \"cloudify_info\" not allowed on remote hosts." 1

    local host="$1"
    shift
    local ipv4
    local ipv6
    while :; do
        [[ -z "$1" ]] && break
        case "$1" in
        -h | --help | help)
            usage_info
            break
            ;;
        ipv4)
            ipv4=$(lxc list "$LXDSERVER:$host" --format=json | jq '.[].state.network.eth0.addresses[] | select (.family=="inet" and .scope=="global") .address')
            echo "$ipv4"
            break
            ;;
        ipv6)
            ipv6=$(lxc list "$LXDSERVER:$host" --format=json | jq '.[].state.network.eth0.addresses[] | select (.family=="inet6" and .scope=="global") .address')
            echo "$ipv6"
            break
            ;;
        -?*) die "Error: Unknown option of info subcommand: '$1'" 1 ;;
        *) break ;;
        esac
        shift
    done
}

# Utility function to add or remove a hostname from '/etc/hosts' (locally or on remote host)
# Usage:    cloudify_hostnames -h|--help|help                       Print help message
#           cloudify_hostnames target_host add hostname             Add hostname IPV4 and IPV6 on target_host /etc/hosts files as 'hostname'
#           cloudify_hostnames target_host add -r hostname          Add hostname IPV4 and IPV6 on target_host /etc/hosts files as 'hostname' and hostname.remote
#           cloudify_hostnames target_host add hostname  IP         Add IP address to target_host /etc/hosts file as 'hostname'
#           cloudify_hostnames target_host add -r hostname  IP      Add IP address to target_host /etc/hosts file as 'hostname' and 'hostname'.remote
# =Todo=
#       - Should exit w/ an error code and a message when things go wrong.
#         This isn't the case yet.
function cloudify_hostnames() {
    local has_opt_remote=false
    local host="$1"
    shift
    local hostname
    local ip
    local ipv4=""
    local ipv6=""
    while :; do
        [[ -z "$1" ]] && break
        case "$1" in
        -h)
            usage_hostnames
            break
            ;;
        add)
            shift
            case "$1" in
            -r)
                shift && has_opt_remote=true
                ;;
            *) ;;

            esac
            hostname="$1"
            ip="$2"
            ipv4=""
            ipv6=""

            if [[ -z $ip ]]; then
                ! $CLOUDIFY_IS_LOCAL && die "Error: Illegal Operation. Calling \"cloudify_hostnames\" without explicit IP is not allowed on remote hosts." 1

                # No IP address was given, As we're running locally, we can asssume access to lxc
                # =Todo= What if lxc isn't intalled?
                if [[ $hostname == localhost || $hostname == "$(hostname)" ]]; then
                    # No need to query LXC :D
                    ip=127.0.0.1
                    ipv6="::1"
                else
                    ip=$(lxc list "$LXDSERVER:$hostname" --format=json | jq -r '.[].state.network.eth0.addresses[] | select (.family=="inet" and .scope=="global") .address')
                    ipv6=$(lxc list "$LXDSERVER:$hostname" --format=json | jq -r '.[].state.network.eth0.addresses[] | select (.family=="inet6" and .scope=="global") .address')
                    [[ -z $ip && -z $ipv6 ]] && die "Error: Unkown hostname $hostname" 1
                fi
            else
                # =Todo= Remove the else branch
                PKG_DEBUG "IP found: $2"
            fi

            # Now we have an IP (or two!), we can go ahead...

            # Manipulate local or remote /etc/host file
            if [[ $host == localhost || $host == "$(hostname)" ]]; then
                # We're manipulating localhost '/etc/hosts' file. Easy, peasy!
                # =Note= The .remote suffix is here to b coherent w/ how cloudify creates new containers
                #        Should we keep it?
                [[ -n "$ip" ]] && {
                    if [[ $has_opt_remote == true && $hostname != localhost && $hostname != "$(hostname)" ]]; then
                        PKG_DEBUG add_in_hosts "$ip $hostname $hostname.remote"
                        add_in_hosts "$ip $hostname $hostname.remote"
                    else
                        PKG_DEBUG add_in_hosts "$ip $hostname"
                        add_in_hosts "$ip $hostname"
                    fi
                }
                [[ -n "$ipv6" ]] && {
                    if [[ $has_opt_remote == true && $hostname != localhost && $hostname != "$(hostname)" ]]; then
                        PKG_DEBUG add_in_hosts "$ipv6 $hostname $hostname.remote"
                        add_in_hosts "$ipv6 $hostname $hostname.remote"
                    else
                        PKG_DEBUG add_in_hosts "$ipv6 $hostname"
                        add_in_hosts "$ipv6 $hostname"
                    fi
                }
            else
                # We're manipulating a remote host '/etc/hosts' file. Neihter easy, nor peasy!
                [[ -z "$ip" ]] && {
                    cloudify_remote "$host" hostnames localhost add "$hostname" "$ipv4"
                }
                [[ -z "$ipv6" ]] && {
                    cloudify_remote "$host" hostnames localhost add "$hostname" "$ipv6"
                }
            fi
            break
            ;;
        -?*) die "Error: Unknown option of info subcommand: '$1'" 1 ;;
        *) break ;;
        esac
        shift
    done
}
