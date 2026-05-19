#!/usr/bin/env bash
# Install fzf

# Declare dependencies
pkg_depends fasd

# --- Install guard ---
if [[ -d "$HOME/.fzf/bin" ]] && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "fzf already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Clear data if requested ---
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    log_info "Clearing fzf data..."
    rm -rf "$HOME/.fzf"
fi

# Installing w/ clone is more robust than using old apt package
if [[ -d "$HOME"/.fzf ]]; then
  (cd "$HOME"/.fzf && git pull)
else
  git clone --depth 1 https://github.com/junegunn/fzf.git "$HOME"/.fzf
fi
"$HOME"/.fzf/install --bin

# Put fzf in the PATH 
ln -sfn "$HOME"/.fzf/bin/fzf "$HOME"/.local/bin/fzf

# Source fzf configuration files for bash 
# shellcheck disable=SC1091 # files are created at runtime by fzf install above
[[ -f "$HOME"/.fzf/shell/key-bindings.bash ]] && source "$HOME"/.fzf/shell/key-bindings.bash
# shellcheck disable=SC1091 # file is created at runtime by fzf install above
[[ -f "$HOME"/.fzf/shell/completion.bash ]] && source "$HOME"/.fzf/shell/completion.bash

# Put env setup in bashrc 
# shellcheck disable=SC2016 # single quotes are intentional: pkg_in_startuprc writes literal strings to .bashrc
pkg_in_startuprc\
    '## FZF SETUP'\
    '[[ -f "$HOME"/.fzf/shell/completion.bash ]] && source "$HOME"/.fzf/shell/completion.bash'\
    '[[ -f "$HOME"/.fzf/shell/key-bindings.bash ]] && source "$HOME"/.fzf/shell/key-bindings.bash' 



