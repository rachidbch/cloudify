# WORKSTATION Installation

# cloud-init user-data
# [TODO] How to set them dynamically?
export GIT_USER=rachidbch
export GIT_EMAIL=rachidbch@gmail.com

# Configuration variables
export EDITOR=vim
export LOCAL_BIN=~/.local/bin
export LOCAL_TMP=~/tmp/
export WORKSTATION_DIR=~/workstation/

[ -d "$LOCAL_BIN" ] || mkdir -p "$LOCAL_BIN"
set PATH=$PATH:"$LOCAL_BIN"

[ -d "$LOCAL_TMP" ] || mkdir -p "$LOCAL_TMP"

# basic apt packages
sudo apt install software-properties-common

# miscelaneous softwares

# GIT_USER and GIT_EMAIL must be sourced from cloudinit user-data
source "$WORKSTATION_DIR"/installs/git/install.sh
source "$WORKSTATION_DIR"/installs/rclone/install.sh
source "$WORKSTATION_DIR"/installs/bat/install.sh
source "$WORKSTATION_DIR"/installs/fzf/install.sh
source "$WORKSTATION_DIR"/installs/git/install.sh
source "$WORKSTATION_DIR"/installs/go/install.sh
source "$WORKSTATION_DIR"/installs/grv/install.sh
source "$WORKSTATION_DIR"/installs/jump/install.sh
source "$WORKSTATION_DIR"/installs/megadown/install.sh
source "$WORKSTATION_DIR"/installs/miniconda3/install.sh
source "$WORKSTATION_DIR"/installs/minikube/install.sh
source "$WORKSTATION_DIR"/installs/mosh/install.sh
source "$WORKSTATION_DIR"/installs/mysql/install.sh
source "$WORKSTATION_DIR"/installs/nvm/install.sh
source "$WORKSTATION_DIR"/installs/php/install.sh
source "$WORKSTATION_DIR"/installs/rclone/install.sh
source "$WORKSTATION_DIR"/installs/ruby/install.sh
source "$WORKSTATION_DIR"/installs/spacemacs/install.sh
source "$WORKSTATION_DIR"/installs/vim/install.sh

