# Install fzf

# Declare dependencies
pkg_depends fasd

# Installing w/ clone is more robust than using old apt package
[ -d ~/.fzf ] || git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
~/.fzf/install --bin                # configuration files are already in dotfiles

# Put fzf in the PATH 
ln -nsf ~/.fzf/bin/fzf ~/.local/bin/fzf

# Source fzf configuration files for bash 
[[ -f ~/.fzf/shell/key-bindings.bash ]] && source ~/.fzf/shell/key-bindings.bash
[[ -f ~/.fzf/shell/completion.bash ]] && source ~/.fzf/shell/completion.bash

# Put env setup in bashrc 
pkg_in_startuprc\
    '## FZF SETUP'\
    '[[ -f ~/.fzf/shell/completion.bash ]] && source ~/.fzf/shell/completion.bash'\
    '[[ -f ~/.fzf/shell/key-bindings.bash ]] && source ~/.fzf/shell/key-bindings.bash' 



