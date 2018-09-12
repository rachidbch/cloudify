sudo apt install git -y

[ -f ~/.gitconfig ] || cat > ~/.gitconfig <<-EOF
    [user]
    email = "$GIT_EMAIL"
    name = "$GIT_USER"
    [core]
    editor = vim
    [diff]
    tool = vimdiff
    [difftool]
    prompt = false
EOF

