WRKFY_DEPS fasd

[ -d ~/.fzf ] || git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
~/.fzf/install --bin                # configuration files are already in dotfiles

source ~/.fzf/shell/completion.bash
[ -f ~/.fzf.bash ] && source ~/.fzf.bash

WRKFY_PKG_ENV=( '## FZF SETUP' '[ -f ~/.fzf.bash ] && source ~/.fzf.bash' )
# This function does the work of inserting statements defined in WRKFY_PKG_ENV above in ~/.bashrc
wrkfy_pkg_startup 


