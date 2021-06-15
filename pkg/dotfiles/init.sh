#!/bin/bash

# To simplify for now we don't use XDG_CONGIG dir. Use it? 
#[ -d ~/.config/dotfiles ] || git clone https://gitlab.com/mobilefirstcentury/dotfiles.git ${XDG_CONFIG_HOME:-~/.config}/dotfiles


# Clone cloudfiles repo
if [ -d ~/dotfiles ]; then
  WRKFY_DEBUG_MSG_NEWLINE "Updating dotfiles"
  ( cd ~/dotfiles; git pull)
else
  WRKFY_DEBUG_MSG_NEWLINE "Downloading dotfiles"
  git clone https://gitlab.com/mobilefirstcentury/dotfiles.git  ~/dotfiles

fi

# Stow!
# Install stow
../stow/init.sh
WRKFY_DEBUG_MSG "Backuping .bashrc"
mv ~/.bashrc.bak.4 ~/.bashrc.bak.5 2>/dev/null 
mv ~/.bashrc.bak.3 ~/.bashrc.bak.4 2>/dev/null
mv ~/.bashrc.bak.2 ~/.bashrc.bak.3 2>/dev/null
mv ~/.bashrc.bak  ~/.bashrc.bak.2 2>/dev/null
mv ~/.bashrc ~/.bashrc.bak
WRKFY_DEBUG_MSG "Setting up dotfiles with stow"
( cd ~/dotfiles; bash ./stow/stowit )

# Add environment variables and aliases
#WRKFY_PKG_ENV=( '## DOTFILES ENV SETUP' )

# This function does the work of updating the values above in ~/.bashrc
wrkfy_pkg_startup_env 


