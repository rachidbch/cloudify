HUGO_VER=0.60.1

[ ! -z $(which wget) ] || apt install -y wget git
[ -d ~/tmp ] || mkdir ~/tmp
wget https://github.com/gohugoio/hugo/releases/download/v${HUGO_VER}/hugo_${HUGO_VER}_Linux-64bit.deb -O~/tmp/hugo.deb

sudo dpkg -i ~/tmp/hugo.deb 

hugo version
