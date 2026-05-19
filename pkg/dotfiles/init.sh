#!/usr/bin/env bash
# Dotfiles Install 

# To simplify for now we don't use XDG_CONGIG dir. Use it? 
#[ -d ~/.config/dotfiles ] || git clone https://gitlab.com/mobilefirstcentury/dotfiles.git ${XDG_CONFIG_HOME:-~/.config}/dotfiles
echo AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAaa
pkg_depends stow

# --- Install guard ---
if [[ -d "$HOME/.dotfiles" ]] && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "dotfiles already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Clear data if requested ---
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    log_info "Clearing dotfiles data..."
    rm -rf "$HOME/.dotfiles"
fi

# Clone cloudfiles repo
if [ -d "$HOME"/.dotfiles ]; then
  PKG_DEBUG 'Updating dotfiles'
  ( cd "$HOME"/.dotfiles || exit 1;
      echo "just before git pull"
      #git pull --recurse-submodules
      git pull
      echo "just after git pull"
      git submodule update --recursive --remote
  )
else
  PKG_DEBUG_LN "Downloading dotfiles"
  git clone --recurse-submodules https://gitlab.com/mobilefirstcentury/dotfiles.git  "$HOME"/.dotfiles
  ( cd "$HOME"/.dotfiles || exit 1; git submodule update --recursive --remote )
fi

PKG_DEBUG "Installing stowit"
ln -sfn "$HOME"/.dotfiles/stow/stowit "$HOME"/.local/bin/stowit
ln -sfn "$HOME"/.dotfiles/stow/unstowit "$HOME"/.local/bin/unstowit

PKG_DEBUG "Setting up dotfiles with stow"
"$HOME"/.local/bin/stowit



