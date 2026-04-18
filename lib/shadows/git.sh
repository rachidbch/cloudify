#!/usr/bin/env bash
# lib/shadows/git.sh - Shadow functions for git (authentication, clone, pull)
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_SHADOW_GIT_LOADED:-}" ]] && return 0
_CLOUDIFY_SHADOW_GIT_LOADED=1

## Git shadowing
function cloudify_git_authenticate() {
    local git_remote_url="${1-}"
    [[ -z "${git_remote_url-}" ]] && PKG_DEBUG "Remote url must be non null." && return 1

    # first backup current .gitconfig
    pkg_backup "$HOME"/.gitconfig

    # Only credentials per git domain are supported so far
    local git_domain
    git_domain=$(cloudify_parse_git_url "$git_remote_url" domain)

    case "${git_domain-}" in
    gitlab.com)
        export GIT_TOKEN="${CLOUDIFY_GITLABPWD:-}"
        ;;
    github.com)
        export GIT_TOKEN="${CLOUDIFY_GITHUBPWD:-}"
        ;;
    *) die "Git Host $git_domain is not supported'" 1 ;;
    esac
    # shellcheck disable=SC2016
    echo 'echo $GIT_TOKEN' >"$HOME"/.git-askpass
    chmod +x "$HOME"/.git-askpass
    export GIT_ASKPASS=$HOME/.git-askpass

    # use 'insteadOf' git feature to force git to use https connection whatever the git url format used
    command git config --global url."https://api@${git_domain}/".insteadOf "https://${git_domain}/"
    command git config --global url."https://ssh@${git_domain}/".insteadOf "ssh://git@${git_domain}/"
    command git config --global url."https://git@${git_domain}/".insteadOf "git@${git_domain}:"
}

# Undo the cloudify_git_authenticate magic
function cloudify_git_deauthenticate() {
    # Undo our git config modifications
    pkg_restore "$HOME"/.gitconfig
}

# Does two remote url refer to the same remote repo?
function cloudify_git_same_remote() {
    local remote_url_1="${1-}"
    local remote_url_2="${2-}"

    local domain_1 domain_2
    local account_1 account_2
    local project_1 project_2

    # Extract account, project, and domain from both URLs using cloudify_parse_git_url
    domain_1=$(cloudify_parse_git_url "${remote_url_1}" domain) || return 1
    account_1=$(cloudify_parse_git_url "${remote_url_1}" account) || return 1
    project_1=$(cloudify_parse_git_url "${remote_url_1}" project) || return 1

    domain_2=$(cloudify_parse_git_url "${remote_url_2}" domain) || return 1
    account_2=$(cloudify_parse_git_url "${remote_url_2}" account) || return 1
    project_2=$(cloudify_parse_git_url "${remote_url_2}" project) || return 1

    # Same repo if domain, account, and project all match
    [[ "$domain_1" == "$domain_2" && "$account_1" == "$account_2" && "$project_1" == "$project_2" ]] && return 0
    return 1
}

# Shadow git
function git() {
    local inside_git_repo=false
    local git_remote_url=""
    local git_repo_path=""
    if [[ "${1-}" == "clone" ]]; then
        # We need to get the remote git host by parsing arguments passed to 'git clone'
        # Any argument that isn't clone or an option, is deemed to be the url to clone
        local arg
        for arg in "$@"; do
            [[ "${arg-}" != "clone" && "${arg-}" != "-*" ]] && {
                if [[ -z "${git_remote_url}" ]] && cloudify_is_git_url "${arg-}"; then
                    git_remote_url="${arg-}"
                else
                    [[ -z "${git_remote_url}" ]] && { PKG_DEBUG "Unable to git clone: Not a valid git url" && return 1; }
                    git_repo_path="${arg-}"
                    # No validity test here as anything can be a path on linux
                    # But we can only clone into an existing folder
                    [[ ! -d $(dirname "${arg-}") ]] && { PKG_DEBUG "Unable to git clone: path $(dirname "${arg-}") doesn't exist." && return 1; }
                    break
                fi
            }
        done

        # If the directory exist, we simply update
        if [[ -d "$git_repo_path" ]] && ! cloudify_emptydir "$git_repo_path"; then
            PKG_DEBUG "$git_repo_path directory exist and isn't empty. Pulling updates."
            (
                cd "$git_repo_path" || exit 1
                inside_git_repo="$(command git rev-parse --is-inside-work-tree 2>/dev/null)"
                $inside_git_repo || { PKG_DEBUG "Can't execute git commands. $git_repo_path isn't a git repo" && return 1; }

                if cloudify_git_same_remote "${git_remote_url}" "$(command git remote get-url origin)"; then
                    #set -x
                    git pull
                    #set +x
                else
                    PKG_DEBUG "Unable to git clone: Repo $(command git remote get-url origin) different from $git_remote_url you trying to clone." && return 1
                fi
            )
        else
            PKG_DEBUG "$git_repo_path doesn't exist directory exist or is empty. cloning"
            cloudify_git_authenticate "$git_remote_url"
            #set -x
            command git "$@" -v
            #set +x
            cloudify_git_deauthenticate "$git_remote_url"
        fi
    else
        # If no git credentials configured, just pass through to real git
        if [[ -z "${CLOUDIFY_GITLABPWD:-}" && -z "${CLOUDIFY_GITHUBPWD:-}" ]]; then
            command git "$@"
            return $?
        fi

        # We can directly read remote url
        inside_git_repo="$(command git rev-parse --is-inside-work-tree 2>/dev/null)"
        if [[ ! "$inside_git_repo" ]]; then
            PKG_DEBUG "Can't execute git commands. $PWD is not inside a git repo."
            return 1
        else
            git_remote_url=$(command git remote get-url origin)
            PKG_DEBUG "Git remote URL: $git_remote_url"
        fi
        cloudify_git_authenticate "$git_remote_url"
        PKG_DEBUG "Actual git command executed:" echo git "$@" -v
        #set -x
        command git "$@" -v
        #set +x
        cloudify_git_deauthenticate "$git_remote_url"
    fi
}
