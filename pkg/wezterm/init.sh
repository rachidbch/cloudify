#!/usr/bin/env bash
# wezterm — GPU-accelerated terminal emulator
# Installs from the apt.fury.io APT repo
# TODO: Cross-distro support — branch to init-<distro>.sh scripts (apt.fury.io is Debian-only;
#       other distros would use GitHub releases via pkg_install_release)

curl -fsSL https://apt.fury.io/wez/gpg.key -o /tmp/wezterm-fury.gpg.key
sudo gpg --yes --dearmor -o /usr/share/keyrings/wezterm-fury.gpg /tmp/wezterm-fury.gpg.key

echo 'deb [signed-by=/usr/share/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *' | sudo tee /etc/apt/sources.list.d/wezterm.list > /dev/null

sudo chmod 644 /usr/share/keyrings/wezterm-fury.gpg

pkg_apt_update

pkg_apt_install wezterm
