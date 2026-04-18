#!/usr/bin/env bash
# lib/package-api.sh - Package management API for cloudify
set -Eeuo pipefail
# Extracted from cloudify monolith

[[ -n "${_CLOUDIFY_PACKAGE_API_LOADED:-}" ]] && return 0
_CLOUDIFY_PACKAGE_API_LOADED=1

#== DEBUG FUNCTIONS
# Print a DEBUG message
function PKG_DEBUG() {
    if $DEBUG; then msg "${RED}*** DEBUG *** ${ORANGE}+(${BASH_SOURCE[0]}:${BASH_LINENO[0]}):${PURPLE} ${FUNCNAME[1]:+${FUNCNAME[1]}()}${ORANGE} ${*} ${RESET}"; fi
}

# Print a DEBUG message after a new line
function PKG_DEBUG_LN() {
    if $DEBUG; then msg "${RED}*** DEBUG *** ${ORANGE}+(${BASH_SOURCE[0]}:${BASH_LINENO[0]}):${PURPLE} ${FUNCNAME[1]:+${FUNCNAME[1]}()}${ORANGE} ${*} ${RESET}"; fi
}

# Simple break command to ease debug
# Pauses until you type enter
function PKG_PAUSE() {
    local _
    if [[ -z $1 ]]; then
        read -rp "Cloudify is paused. Type enter to continue" _
    else
        read -rp "Cloudify is paused at $1. Type enter to continue" _
    fi
}

# Rotate backups up (ascending): .bak→.bak.1→...→.bak.5
# Usage: _cloudify_backup_rotate_up "$backup_name"
function _cloudify_backup_rotate_up() {
    local base="$1"
    rm -rf "${base}.bak.5" 2>/dev/null
    mv "${base}.bak.4" "${base}.bak.5" 2>/dev/null || true
    rm -rf "${base}.bak.4" 2>/dev/null
    mv "${base}.bak.3" "${base}.bak.4" 2>/dev/null || true
    rm -rf "${base}.bak.3" 2>/dev/null
    mv "${base}.bak.2" "${base}.bak.3" 2>/dev/null || true
    rm -rf "${base}.bak.2" 2>/dev/null
    mv "${base}.bak.1" "${base}.bak.2" 2>/dev/null || true
    rm -rf "${base}.bak.1" 2>/dev/null
    mv "${base}.bak" "${base}.bak.1" 2>/dev/null || true
    rm -rf "${base}.bak" 2>/dev/null
    mv "${base}" "${base}.bak" 2>/dev/null || true
    rm -rf "${base}" 2>/dev/null
}

# Rotate backups down (descending): restore from base to restore_path
# Usage: _cloudify_backup_rotate_down "$backup_name" "$restore_path"
function _cloudify_backup_rotate_down() {
    local base="$1"
    local restore_path="$2"
    trash-put "$restore_path" 2>/dev/null || true
    mv "${base}" "$restore_path" 2>/dev/null || true
    rm -rf "${base}" 2>/dev/null
    mv "${base}.bak" "${base}" 2>/dev/null || true
    rm -rf "${base}.bak" 2>/dev/null
    mv "${base}.bak.1" "${base}.bak" 2>/dev/null || true
    rm -rf "${base}.bak.1" 2>/dev/null
    mv "${base}.bak.2" "${base}.bak.1" 2>/dev/null || true
    rm -rf "${base}.bak.2" 2>/dev/null
    mv "${base}.bak.3" "${base}.bak.2" 2>/dev/null || true
    rm -rf "${base}.bak.3" 2>/dev/null
    mv "${base}.bak.4" "${base}.bak.3" 2>/dev/null || true
    rm -rf "${base}.bak.4" 2>/dev/null
    mv "${base}.bak.5" "${base}.bak.4" 2>/dev/null || true
}

# Backup files
# Usage: pkg_backup path            backup file or directory in /tmp/cloudify/backup/
# =DANGER= function full of 'rm -rf'!!
# =Warning= Prevent destructve actions. Example: What happens if called with path '/' ?
function pkg_backup() {
    PKG_DEBUG "Running pkg_backup for ${1-}"

    # Do we keep the same name for the target and its target
    local backup_name
    local same=false
    [[ "${1-}" == "--same" ]] && same=true && shift

    # Guard against destructive paths
    local target="${1:-}"
    [[ -z "$target" ]] && die "pkg_backup: refusing empty argument"
    [[ "$target" == "/" || "$target" == "/root" || "$target" == "/home" || "$target" == "/usr" ]] && \
        die "pkg_backup: refusing to back up system path '$target'"

    if [[ ! -e ${1-} ]]; then
        PKG_DEBUG "File or directory ${1-} not found"
        return 1
    fi

    # Derive a unique file name for the backup by getting the absolute path of the target and replacing by '/' by '__'
    if "$same"; then
        backup_name=$(basename "${1-}")
    else
        backup_name=$(dirname "${1-}")
        backup_name="$(basename "${1-}")${backup_name//\//@}"
    fi
    backup_name="${CLOUDIFY_TMP}"/backup/${backup_name}

    PKG_DEBUG "Backing up ${1-} to ${backup_name}"

    [[ -d "${CLOUDIFY_TMP}"/backup ]] || { PKG_DEBUG "Creating ${CLOUDIFY_TMP}/backup directory" && mkdir -p "${CLOUDIFY_TMP}"/backup; }
    _cloudify_backup_rotate_up "$backup_name"
    cp -paf "$1" "${backup_name}"

    # Break symlinks so modifications to original won't affect the backup
    rm -rf "${backup_name}".atomic 2>/dev/null
    cp -paL --no-preserve=links "$1" "${backup_name}".atomic
    rm -rf "${1}" 2>/dev/null
    cp -paL --no-preserve=links "${backup_name}".atomic "$1"
    rm -rf "${backup_name}".atomic 2>/dev/null

    # Increment backup counter for this file
    [[ -f "${backup_name}.index" ]] || echo "0" >"${backup_name}.index"
    local count
    count=$(cat "${backup_name}.index")
    echo $((count + 1)) >"${backup_name}.index"
}

# Restore file/directory
# Usage: pkg_restore /path/to/file            Backup file or directory in /tmp/cloudify/backup/path/to/file.bak
#                                             If a relative path is given, it is first converted in absolute path
#                                             File can be backed up multiple times ad backup files will be rolled (.bak, .bak.1, ..., .bak.5)
# pkg_restore uses simple 'mv' to restore files.
# This may mess with ownership and permissions...
pkg_restore() {
    PKG_DEBUG "Running Restore"

    [[ ! -d "${CLOUDIFY_TMP}"/backup ]] && PKG_DEBUG "No backup directory found" && return 1

    # Do we keep the same name for the target and its target
    local same=false
    local backup_name
    [[ "${1-}" == "--same" ]] && same=true && shift

    # Derive a unique file name for the backup by getting the absolute path of the target and replacing by '/' by '__'
    if "$same"; then
        backup_name=${1-}
    else
        backup_name=$(dirname "$1")
        backup_name="$(basename "${1-}")${backup_name//\//@}"
    fi
    backup_name="${CLOUDIFY_TMP}"/backup/${backup_name}

    if [[ ! -e "${backup_name-}" && ! -L "${backup_name-}" ]]; then
        PKG_DEBUG "File or directory ${1-} has no backup"
        PKG_DEBUG "File or directory ${backup_name-} doesn't exist"
        return 1
    fi

    PKG_DEBUG "Restoring ${backup_name} to ${1-}"

    _cloudify_backup_rotate_down "$backup_name" "$1"

    # Decrement backup counter for this file
    local count
    count=$(cat "${backup_name}.index")
    count=$((count - 1))
    if [[ $count -gt 0 ]]; then
        echo "$count" >"${backup_name}.index"
    else
        rm -f "${backup_name}.index"
    fi
    return 0 # If we're then everything is ok. Roll back failures are exptected.
}

# Write lines listed as single-quoted arguments in .bashrc
function pkg_in_startuprc() {
    # sed special characters have to be escaped
    local pkg_escaped_lines=()
    local pkg_startuprc_line
    for pkg_startuprc_line in "${@}"; do
        pkg_startuprc_line=$(_cloudify_sed_escape "$pkg_startuprc_line")
        pkg_escaped_lines+=("$pkg_startuprc_line")
    done

    # Reserve cloudify space in bashrc
    grep -qFx "# CLOUDIFY ENV START" "$HOME"/.bashrc || echo -e "\n# CLOUDIFY ENV START\n# CLOUDIFY ENV END" >>"$HOME"/.bashrc

    # Remove previous pkg setup
    for pkg_startuprc_line in "${pkg_escaped_lines[@]}"; do
        sed -i "/$pkg_startuprc_line/d" "$HOME"/.bashrc
    done

    # Insert pkg setup
    #PKG_DEBUG_LN "Inserting pkg setup"
    for pkg_startuprc_line in "${pkg_escaped_lines[@]}"; do
        sed -i "/# CLOUDIFY ENV END/i $pkg_startuprc_line" "$HOME"/.bashrc
    done
}

# Update apt cache
function pkg_apt_update() {

    cloudify_get_password password user host
    # shellcheck disable=SC2154
    [[ -z ${password} ]] && die "Password not set for user $user on host $host."

    if [[ "${1-}" == "--force" || -z "$(find /var/cache/apt/pkgcache.bin -mmin -60)" ]]; then
        PKG_DEBUG "Updating apt packages lists"
        command sudo -kS -p '' apt-get -q update <<<"$password"
        local exitcode=$?
        if [ "$exitcode" -ne 0 ]; then
            die "Error updating apt packages lists:" "$exitcode"
        else
            PKG_DEBUG "Apt packages lists updated."
        fi
    fi
}

# Add apt source
function pkg_apt_repository() {
    cloudify_get_password password user host
    # shellcheck disable=SC2154
    [[ -z ${password} ]] && die "Password not set for user $user on host $host."

    for apt_source in "${@}"; do
        if ! grep -q "^deb .*${apt_source}" /etc/apt/sources.list.d/*; then
            command sudo -kS -p '' add-apt-repository "ppa:${apt_source}" -y <<<"$password"
        fi
    done
    pkg_apt_update --force
}

# Install apt package if not already installed
function pkg_apt_install() {

    cloudify_get_password password user host
    # shellcheck disable=SC2154
    [[ -z ${password} ]] && die "Password not set for user $user on host $host."

    local pkgname=""
    local had_error=0

    pkg_apt_update

    for pkg in "${@}"; do
        # If a deb file is passed, get the package name from it
        # Of course, this only works if deb files are consistently named "/path/to/<package name>.deb"
        if [[ $pkg == *.deb ]] && [[ -f $pkg ]]; then
            pkgname=$(basename "$pkg")
            pkgname=${pkgname%.*}
        else
            pkgname=$pkg
        fi

        PKG_DEBUG_LN "Installing $pkgname apt package"

        if ! dpkg -l "$pkgname" |& grep -q "^ii  $pkgname"; then
            command sudo -kS -p '' apt-get -q install "$pkg" -y <<<"$password"
            local exitcode=$?
            if [ "$exitcode" -ne 0 ]; then
                msg "${RED}Error installing $pkg (exit code $exitcode). Continuing with remaining packages.${RESET}"
                had_error=1
            fi
        else
            PKG_DEBUG_LN "$pkg apt package already present"
        fi
    done
    return "$had_error"
}

# Install latest release from Github
function pkg_install_release() {
    cloudify_get_password password user host
    # shellcheck disable=SC2154
    [[ -z ${password} ]] && die "Password not set for user $user on host $host."

    [[ $# -lt 2 ]] && die "pkg_install_release requires <cmd> <repo>"

    local cmd="$1"
    local repoId="$2"

    # Check required tools
    command -v jq &>/dev/null || die "pkg_install_release requires 'jq' to be installed"
    command -v curl &>/dev/null || die "pkg_install_release requires 'curl' to be installed"

    # Idempotency: skip if binary already installed
    if command -v "$cmd" &>/dev/null; then
        PKG_DEBUG_LN "$cmd already installed, skipping download"
        return 0
    fi

    PKG_DEBUG_LN "Retrieving $repoId last release"
    # amd64 tag
    #    -- tgz or tar.gz
    local release_url
    release_url=$(curl -sSL "https://api.github.com/repos/${repoId}/releases/latest" | jq -r ".assets[].browser_download_url" | grep -ie 'linux' | grep -ie 'amd64\|x86_64' | grep -ive 'musl' | grep -ie '\.tgz\|\.tar\.gz\|\.bz2\|\.tar\.bz2')

    #    -- deb
    [[ -z $release_url ]] && release_url=$(curl -sSL "https://api.github.com/repos/${repoId}/releases/latest" | jq -r ".assets[].browser_download_url" | grep -ie 'linux' | grep -ie 'amd64\|x86_64' | grep -ive 'musl' | grep -ie '\.deb')
    [[ -z $release_url ]] && die "Unable to find 64bits linux release for $repoId"

    PKG_DEBUG_LN "Last release url: $release_url"

    if [[ -n "$cmd" ]]; then
        [[ -d /tmp/"$cmd" ]] && rm -rf /tmp/"$cmd"
        mkdir /tmp/"$cmd"

        if [[ $release_url == *.deb ]]; then
            # Install from deb package
            PKG_DEBUG "Extracting $repoId deb archive in /tmp/${cmd}/${cmd}.deb"
            curl -sSL "$release_url" >"/tmp/${cmd}/${cmd}.deb"
            PKG_DEBUG "Installing $repoId deb package."
            pkg_apt_install "/tmp/${cmd}/${cmd}.deb"
        elif [[ $release_url == *.bz2 ]]; then
            # Install compressed binary
            PKG_DEBUG "Extracting $repoId bz2 binary archive. in /tmp/$cmd/"
            curl -sSL "$release_url" >"/tmp/${cmd}/${cmd}.bz2"
            bzip2 -d "/tmp/${cmd}/${cmd}.bz2" # This creates a /tmp/${cmd}/${cmd} file
            sudo install -m755 "/tmp/${cmd}/${cmd}" "/usr/local/bin/${cmd}"
        else
            # Install binary from tgz archive
            PKG_DEBUG "Extracting $repoId tgz archive. in /tmp/$cmd/"
            curl -sSL "$release_url" | tar -C /tmp/"$cmd" --strip-components=1 -xzf -

            if cloudify_emptydir /tmp/"$cmd"; then
                # Contrary to a widely shared practice, this repo doesn't include a top level folder into its release archive
                curl -sSL "$release_url" | tar -C /tmp/"$cmd" -xzf -
            fi

            PKG_DEBUG "Installing $repoId in /usr/local/bin/"
            (
                # Some install archives have an install/setup script.
                # If that's the case, let it do its thing (A lot of install/setup scripts read the install directory in a prefix variable )
                local script
                for script in install install.sh setup setup.sh; do
                    if [[ -f /tmp/"$cmd"/"$script" ]]; then
                        PKG_DEBUG "Running archive setup script: $script"
                        command sudo -kS -p '' prefix=/usr/local bash "/tmp/$cmd/$script" &>/dev/null <<<"$password"
                        exit 0
                    fi
                done

                # Some install archive contain directly the binary
                [[ -f /tmp/"$cmd"/"$cmd" ]] && PKG_DEBUG "Installing $cmd binary" &&
                    command sudo -kS -p '' install -Dm 755 /tmp/"$cmd"/"$cmd" /usr/local/bin/ &>/dev/null <<<"$password" &&
                    exit 0

                # The 'install' command doesn't have a recursive option. We use find as a workaround
                # This will install each file in the archive at corresping path /usr/local
                # Note we're excluding the first level, as this is the place of files, like LICENSE, that shouldn't be installed
                local release_dir
                for release_dir in 'bin' 'share' 'etc' 'doc'; do
                    [[ -d /tmp/"$cmd"/"$release_dir" ]] && PKG_DEBUG "Installing /tmp/$cmd/$release_dir to /usr/local/$release_dir"
                    if [[ -d /tmp/"$cmd"/"$release_dir" ]]; then
                        (
                            cd /tmp/"$cmd"/"$release_dir" || exit 1
                            command sudo -kS -p '' find . -mindepth 1 -type f -exec install -Dm 755 "{}" "/usr/local/$release_dir/{}" \; &>/dev/null <<<"$password"
                        )
                    fi
                done

                # Some install archive contain directly the binary but w/ a custom name...
                # If the folder contains only one binary, that's the binary we want to install
                local executables
                local executablesCount
                executables=$(find /tmp/"$cmd"/ -maxdepth 1 -type f -executable)
                executablesCount=$(echo "$executables" | wc -l)
                if [[ "$executablesCount" == 1 ]]; then
                    PKG_DEBUG "Installing $executables as /usr/local/bin/$cmd"
                    cp "$executables" "/tmp/$cmd/$cmd"
                    command sudo -kS -p '' install -Dm 755 "/tmp/$cmd/$cmd" /usr/local/bin/ &>/dev/null <<<"$password" && exit 0
                fi
            )
        fi
        # Clean up temp directory
        rm -rf "/tmp/${cmd}"
    fi
}

# Adds a package dependeny
function pkg_depends() {
    local package_recipe_path
    local script_basename
    for pkg in "$@"; do
        # Does the package even exit?
        if cloudify_is_package "$pkg"; then
            PKG_DEBUG "Installing $pkg cloudify package"
            if cloudify_package_has_recipe "$pkg"; then
                package_recipe_path=$(cloudify_package_recipe_path "$pkg")
                PKG_DEBUG sourcing "$package_recipe_path"
                # shellcheck source=/dev/null
                source "$package_recipe_path"
            else
                msg "${GREEN}Package $pkg has no recipe. Trying Native Package Manager.${RESET}"
                pkg_apt_install "${pkg}"
            fi

            # Install package scripts in ~/.local/bin
            for script in "$(dirname "$package_recipe_path")"/*.script; do
                [[ -e "$script" ]] || continue # As per bash normal behaviour, when a glob expansion doesn't match any file,
                # the glob pattern itself is processed. This protects against such a case.
                # Note that this can also be prevented by setting the 'nullglob' option
                script_basename=$(basename "$script")
                PKG_DEBUG copying "$script" to "$CLOUDIFY_LOCAL_BIN"/"${script_basename%.script}"
                cp -paf "$script" "$CLOUDIFY_LOCAL_BIN"/"${script_basename%.script}"
            done
        else
            msg "${GREEN}No package $pkg found. Trying Native Package Manager.${RESET}"
            pkg_apt_install "${pkg}"
        fi
    done
}

# Alias: legacy name kept for backwards compatibility
function cloudify_install_package_release() {
    pkg_install_release "$@"
}
