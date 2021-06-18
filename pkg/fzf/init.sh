# Install fzf

# Declare dependencies
WRKFY_PKG_DEPS fasd

# Installing w/ clone is more robust than using old apt package
[ -d ~/.fzf ] || git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
~/.fzf/install --bin                # configuration files are already in dotfiles

# Put fzf in the PATH 
ln -nsf ~/.fzf/bin/fzf ~/.local/bin/fzf

# Source fzf configuration files for bash 
[[ -f ~/.fzf/shell/key-bindings.bash ]] && source ~/.fzf/shell/key-bindings.bash
[[ -f ~/.fzf/shell/completion.bash ]] && source ~/.fzf/shell/completion.bash

WRKFY_PKG_ENV=( '## FZF SETUP' '[[ -f ~/.fzf/shell/completion.bash ]] && source ~/.fzf/shell/completion.bash' '[[ -f ~/.fzf/shell/key\-bindings.bash ]] && source ~/.fzf/shell/key\-bindings.bash') 

# This function does the work of inserting statements defined in WRKFY_PKG_ENV above in ~/.bashrc
wrkfy_pkg_startup 


