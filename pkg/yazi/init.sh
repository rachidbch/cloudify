#!/usr/bin/env bash
# yazi — blazing fast terminal file manager
# doc: https://yazi-rs.github.io/docs/installation/
# deps: file (prerequisite); fzf (resolved via PATH at runtime, not an apt dep)
#
# WHY STANDALONE BINARY (not .deb): the upstream yazi .deb declares
# `Depends: fzf`, which on Ubuntu 22.04 pulls apt's ancient fzf 0.29 and
# shadows any newer user-installed fzf. The standalone musl binary resolves
# `fzf` via PATH at runtime, so it uses whatever fzf is available (newer wins).
# See leanvim HISTORY.md ADR-006 + the fzf-shadowing roadblock.

if command -v yazi &>/dev/null; then
    PKG_DEBUG "yazi already installed, skipping"
    return 0
fi

pkg_depends file

YAZI_VERSION=$(curl -s "https://api.github.com/repos/sxyazi/yazi/releases/latest" | grep -Po '"tag_name": *"\K[^"]*')
YAZI_ARCH=$(uname -m)

case "$YAZI_ARCH" in
    x86_64)  YAZI_TARGET="x86_64-unknown-linux-musl" ;;
    aarch64) YAZI_TARGET="aarch64-unknown-linux-musl" ;;
    *) die "yazi: unsupported arch $YAZI_ARCH" ;;
esac

YAZI_URL="https://github.com/sxyazi/yazi/releases/download/${YAZI_VERSION}/yazi-${YAZI_TARGET}.zip"

[[ -d /tmp/yazi ]] && rm -rf /tmp/yazi
mkdir -p /tmp/yazi
curl -fsSL "$YAZI_URL" -o /tmp/yazi/yazi.zip
unzip -oq /tmp/yazi/yazi.zip -d /tmp/yazi

PKG_DEBUG "Installing yazi + ya to /usr/local/bin/"
sudo install -Dm755 "/tmp/yazi/yazi-${YAZI_TARGET}/yazi" /usr/local/bin/yazi
sudo install -Dm755 "/tmp/yazi/yazi-${YAZI_TARGET}/ya"   /usr/local/bin/ya

# Shell completions (bash + zsh + fish)
sudo install -Dm644 "/tmp/yazi/yazi-${YAZI_TARGET}/completions/yazi.bash" /usr/share/bash-completion/completions/yazi
sudo install -Dm644 "/tmp/yazi/yazi-${YAZI_TARGET}/completions/ya.bash"   /usr/share/bash-completion/completions/ya
sudo install -Dm644 "/tmp/yazi/yazi-${YAZI_TARGET}/completions/_yazi"     /usr/local/share/zsh/site-functions/_yazi
sudo install -Dm644 "/tmp/yazi/yazi-${YAZI_TARGET}/completions/_ya"       /usr/local/share/zsh/site-functions/_ya
sudo install -Dm644 "/tmp/yazi/yazi-${YAZI_TARGET}/completions/yazi.fish" /usr/share/fish/vendor_completions.d/yazi.fish
sudo install -Dm644 "/tmp/yazi/yazi-${YAZI_TARGET}/completions/ya.fish"   /usr/share/fish/vendor_completions.d/ya.fish

rm -rf /tmp/yazi

pkg_in_startuprc "alias y=yazi"
