# Install git

pkg_apt_install git


# =TODO= What's this?
# Install git-lab subcommand
#sudo install -m755 $PKG_DIR/git-lab /usr/local/bin/


# =TODO= If ~/.gitconfig doesn't exist and GIT_EMAIL and GIT_USER are set, create ~/.gitconfig file 
#[ -f ~/.gitconfig ] || cat > ~/.gitconfig <<-EOF
#    [user]
#    email = "$GIT_EMAIL"
#    name = "$GIT_USER"
#    [core]
#    editor = vim
#    [diff]
#    tool = vimdiff
#    [difftool]
#    prompt = false
#EOF
