#!/usr/bin/env bash
# yazi — blazing fast terminal file manager
# doc: https://yazi-rs.github.io/docs/installation/
# deps: file (prerequisite)

if command -v yazi &>/dev/null; then
    PKG_DEBUG "yazi already installed, skipping"
    return 0
fi

pkg_depends file

distro=$(cloudify_osdetect --distro)
version=$(cloudify_osdetect --version)

# Use system glibc .deb on newer distros, musl .deb on older (Ubuntu < 24.04, Debian < 13)
if { [[ "$distro" == "ubuntu" ]] && cloudify_ver_cmp "$version" ">=" "24.04"; } || \
   { [[ "$distro" == "debian" ]] && cloudify_ver_cmp "$version" ">=" "13"; }; then
    pkg_install_release yazi "sxyazi/yazi"
else
    YAZI_VERSION=$(curl -s "https://api.github.com/repos/sxyazi/yazi/releases/latest" | grep -Po '"tag_name": *"\K[^"]*')
    YAZI_ARCH=$(uname -m)
    curl -Lo /tmp/yazi.deb "https://github.com/sxyazi/yazi/releases/download/${YAZI_VERSION}/yazi-${YAZI_ARCH}-unknown-linux-musl.deb"
    pkg_apt_install /tmp/yazi.deb
    rm -f /tmp/yazi.deb
fi

pkg_in_startuprc "alias y=yazi"
