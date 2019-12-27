# This may be usefull temporarily until we can clone dotfiles
PKG_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
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

# Install Hub
HUB_VER=2.13.0
(
  [ -z ~/tmp ] && mkdir ~/tmp
  cd ~/tmp
  curl -sSL "https://github.com/github/hub/releases/download/v${HUB_VER}/hub-linux-amd64-${HUB_VER}.tgz" > hub.tgz
  [ -d hub ] && rm -rf ./hub/* || mkdir hub
  tar xvzf hub.tgz --strip-components=1 -C hub
  cd hub
  sudo  prefix=/usr/local ./install
)
# Install Lab
latest="$(curl -sL 'https://api.github.com/repos/zaquestion/lab/releases/latest' | grep 'tag_name' | grep --only 'v[0-9\.]\+' | cut -c 2-)"
curl -sL "https://github.com/zaquestion/lab/releases/download/v${latest}/lab_${latest}_linux_amd64.tar.gz" | tar -C ~/tmp/ -xzvf -
sudo install -m755 ~/tmp/lab /usr/local/bin/lab

# Install git-lab subcommand
sudo install -m755 $PKG_DIR/git-lab /usr/local/bin/
