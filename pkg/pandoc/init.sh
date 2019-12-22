# install latest version of pandoc as it tends to be outdated in official repos
# versions 1.x of pandoc don't manage well htlm to org conversion

PANDOC_VER=2.9.1

[ ! -d ~/tmp/ ] && mkdir ~/tmp

(
  cd ~/tmp
  curl -sSL "https://github.com/jgm/pandoc/releases/download/${PANDOC_VER%.*}/pandoc-${PANDOC_VER%.*}-${PANDOC_VER##*.}-amd64.deb" > pandoc.deb
  sudo dpkg -i pandoc.deb 
)
