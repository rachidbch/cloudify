# Dotfiles Install 

# To simplify for now we don't use XDG_CONGIG dir. Use it? 
#[ -d ~/.config/dotfiles ] || git clone https://gitlab.com/mobilefirstcentury/dotfiles.git ${XDG_CONFIG_HOME:-~/.config}/dotfiles

pkg_depends stow 

# Clone cloudfiles repo
if [ -d "$HOME"/.dotfiles ]; then
  PKG_DEBUG_LN "Updating dotfiles"
  ( cd "$HOME"/.dotfiles;   
    # Decide if the remote is on github or gitlab
    local git_origin=$(git remote get-url origin)
    #origin_with_pass=${origin/"//"/"//${USER_ID}:${USER_PW}@"}
    #git pull ${origin_with_pass} master 

    local is_gitlab=$( echo "$git_origin" | grep -Fq gitlab.com )
    local is_github=$( echo "$git_origin" | grep -Fq github.com )

    if "$is_gitlab"; then
      git pull --recurse-submodules <<< "$CLOUDIFY_GITLABUSER\n$CLOUDIFY_GITLABPWD"
      git submodule update --recursive --remote  <<< "$CLOUDIFY_GITLABUSER\n$CLOUDIFY_GITLABPWD"
    elif "$is_github"; then
      git pull --recurse-submodules <<< "$CLOUDIFY_GITHUBUSER\n$CLOUDIFY_GITHUBPWD"
      git submodule update --recursive --remote <<< "$CLOUDIFY_GITHUBUSER\n$CLOUDIFY_GITHUBPWD"
    else
      die "Remote git of package $(git remote show origin | grep -F Fetch | cut  -d' ' -f5) not supported" 1
    fi
  )
else
  PKG_DEBUG_LN "Downloading dotfiles"
  git clone --recurse-submodules https://gitlab.com/mobilefirstcentury/dotfiles.git  "$HOME"/.dotfiles
  ( cd "$HOME"/.dotfiles; git submodule update --recursive --remote )
fi

PKG_DEBUG "Backuping up .bashrc"
[[ -d "$CLOUDIFY_TMP"/backup ]] || mkdir "$CLOUDIFY_TMP"/backup 
mv "$CLOUDIFY_TMP"/backup/.bashrc.bak.4 "$CLOUDIFY_TMP"/backup/.bashrc.bak.5 2>/dev/null 
mv "$CLOUDIFY_TMP"/backup/.bashrc.bak.3 "$CLOUDIFY_TMP"/backup/.bashrc.bak.4 2>/dev/null
mv "$CLOUDIFY_TMP"/backup/.bashrc.bak.2 "$CLOUDIFY_TMP"/backup/.bashrc.bak.3 2>/dev/null
mv "$CLOUDIFY_TMP"/backup/.bashrc.bak  "$CLOUDIFY_TMP"/backup/.bashrc.bak.2 2>/dev/null
mv "$CLOUDIFY_TMP"/bashrc "$CLOUDIFY_TMP"/backup/.bashrc.bak

PKG_DEBUG "Installing stowit"
ln -sfn "$HOME"/.dotfiles/stow/stowit "$HOME"/.local/bin/stowit
ln -sfn "$HOME"/.dotfiles/stow/unstowit "$HOME"/.local/bin/unstowit

PKG_DEBUG "Setting up dotfiles with stow"
"$HOME"/.local/bin/stowit



