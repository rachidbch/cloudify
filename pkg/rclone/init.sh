#!/usr/bin/env bash
# Rclone Installation

pkg_depends jq
pkg_install_release rclone "rclone/rclone"

# Create a S3 Rclone remote in ~/.config/rclone/rclone.conf by evaluating ./rclone.conf and copying on the host
# =NOTE= This is done to prevent leaking credentials in git repos as the rclone.conf template committed only contains environment variable names
PKG_DEBUG "${RED}Creating ${HOME}/.config/rclone/rclone.conf file"
# shellcheck disable=SC2002 # cat used for readability in pipeline with envsubst
cat "$HOME/cloudify/pkg/rclone/rclone.conf" | envsubst | tee "${HOME}/.config/rclone/rclone.conf" &>/dev/null
PKG_DEBUG "${RED}Created ${HOME}/.config/rclone/rclone.conf file"
