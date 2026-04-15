# Type Ctrl+E to select a file to edit
#
# Installation
# =TODO=  Source from ~/.zshrc

# =WARNING= Compatible w/zsh only.
#           =TODO= Make it compatible with bash too


fuzzedit() {
    local target
    target=$( fd -t file . "$HOME" --hidden | fzf -m )
    [[ -z $target ]] && zle reset-prompt && return 0
    [[ -f $target ]] && ${EDITOR-vim} "$target" </dev/tty
    zle reset-prompt
}

zle -N fuzzedit

#bindkey -e
bindkey "^f" fuzzedit
