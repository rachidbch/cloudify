#!/usr/bin/env bash
# lazygit — simple terminal UI for git commands
# doc: https://github.com/jesseduffield/lazygit

# Idempotency: skip if already installed
if command -v lazygit &>/dev/null; then
    PKG_DEBUG "lazygit already installed, skipping"
    return 0
fi

distro=$(cloudify_osdetect --distro)
version=$(cloudify_osdetect --version)

# Debian 13+, Ubuntu 25.10+ have lazygit in apt
if { [[ "$distro" == "debian" ]] && cloudify_ver_cmp "$version" ">=" "13"; } || \
   { [[ "$distro" == "ubuntu" ]] && cloudify_ver_cmp "$version" ">=" "25.10"; }; then
    pkg_apt_install lazygit
else
    pkg_depends curl
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": *"v\K[^"]*')
    LAZYGIT_ARCH=$(uname -m | sed -e 's/aarch64/arm64/')
    curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${LAZYGIT_ARCH}.tar.gz"
    tar xf lazygit.tar.gz lazygit
    sudo install lazygit -D -t /usr/local/bin/
    rm -f lazygit lazygit.tar.gz
fi

pkg_in_startuprc "alias lg=lazygit"
