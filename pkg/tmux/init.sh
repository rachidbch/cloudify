# Installing tmux
pkg_apt_install tmux

# Tmux won't abide by XDG BASE DIRECTORY spec.
# This alias is a work around sourced [[https://github.com/tmux/tmux/issues/142#issuecomment-329946562][here]]
# alias tmux='TERM=xterm-256color tmux -f "${XDG_CONFIG_HOME:-~/.config}"/tmux/tmux.conf'

# Setup in ~/.bashrc 
pkg_in_startuprc \
    '## TMUX SETUP' \
    'alias tmux='\''TERM=xterm-256color tmux -f "${XDG_CONFIG_HOME:-~/.config}"/tmux/tmux.conf\'\'''


