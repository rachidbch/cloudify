# fzf based Command line bookmarks
# Jump to your bookmarks with 'Ctrl+J'
# 
# Store you bookmarks in ~/_/bookmarks (1 per line)
# Bookmarks can have absolute or relative (to HOME) paths
# Bookmarks that doesn't contain any '/' are read from $HOME/_/
# (This is an nice way to have nicely named bookmarks: Create them as symlinks in $HOME/_/ directory)


# Must be source from ~/.zshrc

# =WARNING= Compatible w/zsh only. 
# =TODO= Make it compatible with bash too


export FZF_DEFAULT_OPTS="--height 70% --layout=reverse"

# Jump makes use of $HOME/_/ directory to store bookmarks 
[[ ! -d $HOME/_/ ]] && mkdir $HOME/_
# bookmarks are listed in $HOME/_/bookmarks text file
[[ ! -f $HOME/_/bookmarks ]] && echo "bookmarks" > $HOME/_/bookmarks

jump() {
    local target  
    local topdir
    
    # Use fzf to select a line from ~/_/bookmarks
    target=$(cat ~/_/bookmarks| fzf ) 
    [[ -z $target ]] && zle reset-prompt && return 0
     
    # Evaluate any environment variable contained in the selected line
    target=$(envsubst <<<"$target")

    
    # Get rid of '~' if any
    [[ ${target:0:2}  == '~/' ]] && target="${HOME}"/"${target:2}"

    # Non absolute paths must be dealt with
    if [[ ! ${target:0:1}  == '/' ]]; then
        topdir=$(cut -d/ -f1 <<<"$target")
        if [[ -f "$HOME/_/$target" || -d "$HOME/_/$target" ||  -L "$HOME/_/$target" || -f "$HOME/_/$topdir" || -d "$HOME/_/$topdir" || -L "$HOME/_/$topdir" ]]; then
            target="$HOME/_/$target"
        else
            # Relative to the home directory
            target="$HOME"/"$target"
        fi
    fi
    
    # cd into dirs and edit files
    [[ -d $target ]] && cd "$target"
    [[ -f $target ]] && ${EDITOR-vim} "$target" </dev/tty 
    target=$(basename $target)
    [[ $target == "daily" ]] && ${EDITOR-vim} ~/KDB/obsidian/Daily\ Notes/$( ls -r ~/KDB/obsidian/Daily\ Notes/ | fzf -m ) </dev/tty

    zle reset-prompt
  }

zle -N jump

#bindkey -e
bindkey "^j" jump
