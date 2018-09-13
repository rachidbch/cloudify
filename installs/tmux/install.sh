sudo apt install tmux -y
# tmux won't abide by XDG BASE DIRECTORY spec.
# this is a work around sourced [[https://github.com/tmux/tmux/issues/142#issuecomment-329946562][here]]
alias tmux='TERM=xterm-256color tmux -f "${XDG_CONFIG_HOME:-~/.config}"/tmux/tmux.conf'
