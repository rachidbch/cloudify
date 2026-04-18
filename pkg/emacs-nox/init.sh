#!/usr/bin/env bash
# Emacs (no X) installation

DISTRO_VER="$(cloudify_osdetect --version)"

if cloudify_ver_cmp "$DISTRO_VER" ">=" "24.04"; then
    # Ubuntu 24.04+ ships emacs 29 directly
    pkg_apt_install emacs-nox
else
    # Older Ubuntu: use kelleyk PPA for recent emacs
    pkg_apt_repository "kelleyk/emacs"
    pkg_apt_install emacs26-nox
fi
