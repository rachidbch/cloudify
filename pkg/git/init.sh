# This may be usefull temporarily until we can clone dotfiles
export GIT_USER=rachidbch
export GIT_EMAIL=rachidbch@gmail.com

sudo apt-get -q install git -y

# Not needed as it's already managed in dotfiles
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
