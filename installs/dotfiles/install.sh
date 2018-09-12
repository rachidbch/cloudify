#!/usr/bin/env bash

# clone dotfiles repo

[ -d ~/.config/dotfiles ] || git clone https://gitlab.com/mobilefirstcentury/dotfiles.git ~/.config/dotfiles
# generate symlinks for softwares not respecting XDG Base Directory Spec.
# the script would not work if sourced, so we have to execute it
chmod +x ~/.config/dotfiles/install.sh
~/.config/dotfiles/install.sh
