#!/usr/bin/env bash
# lib/packages.sh - Package management functions for cloudify
set -Eeuo pipefail
# Extracted from cloudify monolith

[[ -n "${_CLOUDIFY_PACKAGES_LOADED:-}" ]] && return 0
_CLOUDIFY_PACKAGES_LOADED=1

#== SCRIPT SUB-COMMANDS: PACKAGE MANAGEMENT

# Does a package exist ?
# Usage:
#   cloudify_is_package
#   Usage:
#       cloudify_is_package pkg                       # Test if package exist
function cloudify_is_package() {
    [[ $# == 0 ]] && return 1 # With no package, return false
    find "$CLOUDIFY_DIR"/pkg/"$1" -maxdepth 0 -exec basename {} \; 2>/dev/null || true
}

# List packages OS tags
function cloudify_list_packages_hashtags() {
    find "$CLOUDIFY_DIR"/pkg -mindepth 2 -maxdepth 2 -name '#*' -exec basename {} \; | awk '!a[$0]++'
    local exitcode=$?
    [[ $exitcode == 0 ]] && echo @allos
    return $exitcode
}

# List packages tags
function cloudify_list_packages_tags() {
    $CLOUDIFY_IS_LOCAL && die "Error: Can't list Tags on remote hosts." 1
    find "$CLOUDIFY_DIR"/pkg -mindepth 2 -maxdepth 2 -name '@*' -exec basename {} \; | awk '!a[$0]++'
    echo @default
    echo @all
}

# List packages filtered by tags
# Usage:
#   cloudify_list_packages_by_tags
#   Usage:
#       cloudify_list_packages_by_tags  [#hashtag] [@tag...]     # Return packages with taged with ALL specified tags
#                                                              # So: cloudify_list_packages_by_tags #linux #default
#                                                              #     Returns packages taged #linux AND #default
#       cloudify_list_packages_by_tags                         # Return all packages
#       cloudify_list_packages_by_tag  pkg                     # Return pkg name if it exists
#                                                              This is useful to check if a package exist
function cloudify_list_packages_by_tags() {
    # The awk incantation is here to remove dubplicates while conserving order
    {
        local current_packages_list
        local packages_list=""
        local filter

        # Without tag filter, return all packages
        # Remove packages duplicates while retaining packages order (see awk incantation below)
        [[ $# == 0 ]] && packages_list=$(find "$CLOUDIFY_DIR"/pkg -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | tr '\n' ' ')

        # If multiple tags are given, list the packages that have all of them
        for filter in "$@"; do
            if ! [[ "$filter" == \@* || "$filter" == \#* ]]; then
                # This isn't a tag. Do nothing.
                :
            else
                # This is a tag

                # unlike '#' tags (aka hashtags), normal '@' tags can't be taken for granted on remote hosts
                ! $CLOUDIFY_IS_LOCAL && [[ "$filter" == \@* ]] &&
                    die "{$RED}Error: Illegal tag $filter. Can't filter packages by tags on remote hosts. ${RESET}"

                # If filter is a tag, filter all packages with that tag
                if [[ $filter == @all ]]; then
                    current_packages_list=$(find "$CLOUDIFY_DIR"/pkg -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | tr '\n' ' ')
                else
                    current_packages_list=$(find "$CLOUDIFY_DIR"/pkg -mindepth 2 -maxdepth 2 -name "$filter" | while read -r d; do basename "$(dirname "$d")"; done | tr '\n' ' ')
                fi

                if [[ -z $packages_list ]]; then
                    packages_list=$current_packages_list
                else
                    # 'comm' is a standard linux utility that compares FILES line by line
                    # It is used here to find the intersection of 2 LISTS
                    # The 'echo ... | tr ...' is here to transform lists in simili-files that can be fed to comm command
                    packages_list=$(comm -12 <(echo "$packages_list" | tr ' ' '\n') <(echo "$current_packages_list" | tr ' ' '\n'))
                fi
            fi
        done
        echo "$packages_list"
    } | awk '!a[$0]++'
}

# List all available packages for current platform
# Usage:
#   cloudify_list_packages                 List available packages for current OS
#   cloudify_list_packages OS              List available package for OS Operating System
function cloudify_list_packages() {
    local os="$1"
    [[ -z $os ]] && os=$(cloudify_osdetect --os)
    cloudify_list_packages_by_tags "#${os}"
}

# List default available packages for current platform
# Usage:
#   cloudify_list_packages                 List default packages for current OS
#   cloudify_list_packages OS              List default package for OS Operating System
# shellcheck disable=SC2120
function cloudify_list_default_packages() {
    $CLOUDIFY_IS_LOCAL || die "{$RED}Error: Illegal Operation. Can't list default packages on remote host $(hostname). ${RESET}"
    local os="${1-}"
    [[ -z $os ]] && os=$(cloudify_osdetect --os)
    cloudify_list_packages_by_tags "#${os}" @default
}

# Test if a package has a recipe
function cloudify_package_has_recipe() {
    # The easiest way to do that is to call 'cloudify_package_recipe_path' and propagate its exit code
    cloudify_package_recipe_path "$1"
    return $?
}

# Print path of package recipe
# Usage:
#   cloudify_package_recipe_path package                Get the path of the recipe of package 'package'
function cloudify_package_recipe_path() {
    local os
    local distro
    local version
    os=$(cloudify_osdetect --os)
    distro=$(cloudify_osdetect --distro)
    version=$(cloudify_osdetect --version)
    local pkg="$1"

    [[ -z $1 ]] && die "Missing argument: package name"

    # Return recipe file (gives higher priority to recipes with higher specificity)
    local recipe
    recipe="$CLOUDIFY_DIR/pkg/${pkg}/${version}.${distro}.${os}.${CLOUDIFY_RECIPE_FILENAME}"
    [[ -n $version ]] && [[ -n $distro ]] && [[ -n $os ]] &&
        [[ -f "$recipe" ]] && echo "$recipe" && return 0

    recipe="$CLOUDIFY_DIR/pkg/${pkg}/${distro}.${os}.${CLOUDIFY_RECIPE_FILENAME}"
    [[ -n $distro ]] && [[ -n $os ]] &&
        [[ -f "$recipe" ]] && echo "$recipe" && return 0

    recipe="$CLOUDIFY_DIR/pkg/${pkg}/${os}.${CLOUDIFY_RECIPE_FILENAME}"
    [[ -n $os ]] &&
        [[ -f "$recipe" ]] && echo "$recipe" && return 0

    recipe="$CLOUDIFY_DIR/pkg/${pkg}/${CLOUDIFY_RECIPE_FILENAME}"
    [[ -f "$recipe" ]] && echo "$recipe" && return 0

    return 1 # No path found
}

# Print package recipe (ie the content of package's recipe file)
function cloudify_print_package_recipe() {
    # Show module code of packages
    local package_recipe_path
    for pkg in "$@"; do
        if cloudify_is_package "$pkg"; then
            package_recipe_path=$(cloudify_package_recipe_path "$pkg")
            if [[ -n $package_recipe_path ]]; then
                msg "${GREEN}${pkg%%*( )} cloudify package code\n${RESET}"
                msg "${GREEN}>> Recipe: ${package_recipe_path}${RESET}"
                cat "$package_recipe_path"
                # We use bash expansion to trim spaces at the end of the package name
                # Kept this line because it was doing fine with this weird variable subsitution incantation that I don't understand
                # Something tells me that this was fixing a bug that has yet to come and bite me....
                # cat "$CLOUDIFY_DIR"/pkg/${pkg%%*( )}/${pkg_init_file}
            else
                msg "${GREEN}No recipe found for package \"${pkg}\".${RESET}"
            fi
        else
            msg "${RED}Error: \"${pkg}\" isn't a known package.${RESET}"
        fi
    done
}

# Install default packages for current platform
# =Note= This will fail if executed on remote host. This is expected.
function cloudify_install_default_packages {
    local pkg
    # shellcheck disable=SC2119
    for pkg in $(cloudify_list_default_packages); do
        msg "${GREEN}Installing ${pkg%%*( )} cloudify package${RESET}"
        pkg_depends "$pkg"
    done
    cloudify_print_done
}

# Install package or packages
# Usage:
#   cloudify_install_package  pkg [pkg...]                      Install one or serveral packages designated by name
#                                                               Tags can't be used as arguments of cloudify_install_packages
function cloudify_install_package {
    # Install specific packages
    local pkg
    for pkg in "$@"; do
        if [[ "$pkg" != @* && "$pkg" != \#* ]]; then
            # Current pkg isn't a tag
            msg "${GREEN}Installing ${pkg%%*( )} cloudify package${RESET}"
            pkg_depends "$pkg"
        else
            # Current pkg is a tag. Log Error and ignore
            msg "${RED}Error: Illegal tag. Cloudify_install_package does't accept tags as arguments. Ignoring \"$pkg\" Installation.${RESET}"
            # # Current argument is a tag
            # local tag="$pkg"
            # msg "${GREEN}Installing ${pkg%%*( )} cloudify packages${RESET}"
            # for pkg in $(packages "$tag"); do
            # cloudify_install_package "$pkg"
            # done
        fi
    done
    ${SKIPDONEMESSAGE:-false} || cloudify_print_done
}

# Uninstall Default packages
function cloudify_uninstall_default_packages {
    die "Uninstall package features not ready." 1
}
# Uninstall one or several package by name
function cloudify_uninstall_package {
    die "Uninstall package features not ready." 1
}
