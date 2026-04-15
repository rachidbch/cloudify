# Type Ctrl+H to show transient help screen with Shortkeys 
# 
# List shortkeys in ~/_/shortkeys (In column presentation)

# Installation
# =TODO=  Source from ~/.zshrc

# =WARNING= Compatible w/zsh only. 
#           =TODO= Make it compatible with bash too

# shortkeys makes use of $HOME/_/ directory to store shortkeys 
#[[ ! -d $HOME/_/ ]] && mkdir $HOME/_

# shortkeys file is listed in $HOME/_/bookmarks text file
#[[ ! -f $HOME/_/shortkeys ]] && echo "shortkeys" > $HOME/_/bookmarks

shortkeys() {
    less -Ri $HOME/_/shortkeys 

    zle reset-prompt
  }

zle -N shortkeys

#bindkey -e
bindkey "^h" shortkeys 
