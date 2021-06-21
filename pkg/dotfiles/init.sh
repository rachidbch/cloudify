#!/bin/bash

# To simplify for now we don't use XDG_CONGIG dir. Use it? 
#[ -d ~/.config/dotfiles ] || git clone https://gitlab.com/mobilefirstcentury/dotfiles.git ${XDG_CONFIG_HOME:-~/.config}/dotfiles


# Clone cloudfiles repo
if [ -d ~/dotfiles ]; then
  PKG_DEBUG_LN "Updating dotfiles"
  ( cd ~/dotfiles; git pull --recurse-submodules )
  ( cd ~/dotfiles; git submodule update --recursive --remote )
else
  PKG_DEBUG_LN "Downloading dotfiles"
  git clone --recurse-submodules https://gitlab.com/mobilefirstcentury/dotfiles.git  ~/dotfiles
  ( cd ~/dotfiles; git submodule update --recursive --remote )
fi

# Stow!
# Install stow
source "$WRKFY_DIR"/pkg/stow/init.sh

PKG_DEBUG "Backuping .bashrc"
mv ~/.bashrc.bak.4 ~/.bashrc.bak.5 2>/dev/null 
mv ~/.bashrc.bak.3 ~/.bashrc.bak.4 2>/dev/null
mv ~/.bashrc.bak.2 ~/.bashrc.bak.3 2>/dev/null
mv ~/.bashrc.bak  ~/.bashrc.bak.2 2>/dev/null
mv ~/.bashrc ~/.bashrc.bak
PKG_DEBUG "Setting up dotfiles with stow"

PKG_DEBUG "Installing stowit"
ln -nsf ~/dotfiles/stow/stowit ~/.local/bin/stowit
ln -nsf ~/dotfiles/stow/unstowit ~/.local/bin/unstowit
~/.local/bin/stowit



