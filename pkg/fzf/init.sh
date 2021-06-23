# Install fzf

# Declare dependencies
pkg_depends fasd

# Installing w/ clone is more robust than using old apt package
if [[ -d "$HOME"/.fzf ]]; then
   git clone --depth 1 https://github.com/junegunn/fzf.git "$HOME"/.fzf
   "$HOME"/.fzf/install --bin                # configuration files are already in dotfiles
else
  (cd "$HOME"/.fzf && git pull)
fi

# Put fzf in the PATH 
ln -sfn "$HOME"/.fzf/bin/fzf "$HOME"/.local/bin/fzf

# Source fzf configuration files for bash 
[[ -f "$HOME"/.fzf/shell/key-bindings.bash ]] && source "$HOME"/.fzf/shell/key-bindings.bash
[[ -f "$HOME"/.fzf/shell/completion.bash ]] && source "$HOME"/.fzf/shell/completion.bash

# Put env setup in bashrc 
pkg_in_startuprc\
    '## FZF SETUP'\
    '[[ -f "$HOME"/.fzf/shell/completion.bash ]] && source "$HOME"/.fzf/shell/completion.bash'\
    '[[ -f "$HOME"/.fzf/shell/key-bindings.bash ]] && source "$HOME"/.fzf/shell/key-bindings.bash' 



