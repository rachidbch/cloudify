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
