# Installing tmux

dpkg -l tmux |& grep -q "^ii  tmux" || WRKFY_DEBUG_MSG_NEWLINE "Installing tmux" && sudo apt-get -q install tmux  -y

# Tmux won't abide by XDG BASE DIRECTORY spec.
# This alias is a work around sourced [[https://github.com/tmux/tmux/issues/142#issuecomment-329946562][here]]
# alias tmux='TERM=xterm-256color tmux -f "${XDG_CONFIG_HOME:-~/.config}"/tmux/tmux.conf'
WRKFY_PKG_ENV=( '## TMUX ENV SETUP' 'alias tmux='\''TERM=xterm-256color tmux -f "${XDG_CONFIG_HOME:-~/.config}"/tmux/tmux.conf\'\''')

# This function does the work of updating the values above in ~/.bashrc
wrkfy_pkg_startup 


