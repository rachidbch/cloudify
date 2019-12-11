# Workstation installation

# DEBUG or NOT
WORKSTATION_DEBUG=true


# =warning= this script must be SOURCED and not executed  (otherwise environment modifcations, like aliases, won't persist after exectution)
# cloud-init user-data
# =todo= GIT_USER and GIT_EMAIL must be sourced from cloudinit user-data

[ -z "$WORKSTATION_DEBUG" ] || echo -e "Setting Exports...\n***"
export GIT_USER=rachidbch
export GIT_EMAIL=rachidbch@gmail.com
# Configuration variables
export EDITOR=vim
export WORKSTATION_DIR=~/workstation/
export LOCAL_BIN=~/.local/bin
[ -d "$LOCAL_BIN" ] || mkdir -p "$LOCAL_BIN"
set PATH=$PATH:"$LOCAL_BIN"
export LOCAL_TMP=~/tmp/
[ -d "$LOCAL_TMP" ] || mkdir -p "$LOCAL_TMP"
# basic apt packages
# =todo= create a basic package in workstation project

# Some stations come without proper locales
# On RackNerd VPS, I had a lot of " perl: warning: Setting locale failed." errors
# =todo= Some advise to be selective and install only needed locales. How?
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling Language pack\n***"
sudo apt-get -q install language-pack-en -y

# Without software-propreties-common this no add-apt-repository ...
# Add a mini comment to explain other installs
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling basics\n***"
sudo apt-get -q install apt-transport-https ca-certificates curl gnupg-agent software-properties-common -y

# Is a linux machine even possible without python
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling python\n***"
source "$WORKSTATION_DIR"/installs/python/install.sh

# version management tools
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling git\n***"
source "$WORKSTATION_DIR"/installs/git/install.sh

# Believe it or not bash-it complains if he doesn't see pyenv!  =todo= remove this dependency
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling virtualenv\n***"
source "$WORKSTATION_DIR"/installs/virtualenv/install.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling pyenv\n***"
source "$WORKSTATION_DIR"/installs/pyenv/install.sh

# Why is the is this needed by bash-it!   =todo= remove this dependency
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling fasd\n***"
source "$WORKSTATION_DIR"/installs/fasd/install.sh

# Import and setup our dotfiles
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling dotfiles\n***"
source "$WORKSTATION_DIR"/installs/dotfiles/install.sh


# bash  (bash-it install has a flag raised to not touch ~/.bashrc has it has already been set by dotfiles package above)
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling bash-it\n***"
source "$WORKSTATION_DIR"/installs/bash-it/install.sh

# miscelaneous softwares

## ssh management
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling mosh\n***"
source "$WORKSTATION_DIR"/installs/mosh/install.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling tmux\n***"
source "$WORKSTATION_DIR"/installs/tmux/install.sh

## programming languages
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling pip\n***"
source "$WORKSTATION_DIR"/installs/pip/install.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling nvm\n***"
source "$WORKSTATION_DIR"/installs/nvm/install.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling go\n***"
source "$WORKSTATION_DIR"/installs/go/install.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\n\nInstalling php\n***"
source "$WORKSTATION_DIR"/installs/php/install.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling ruby\n***"
source "$WORKSTATION_DIR"/installs/ruby/install.sh
#[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling miniconda3\n***"
#source "$WORKSTATION_DIR"/installs/miniconda3/install.sh

# miscellaneous tools
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling toto.txt\n***"
source "$WORKSTATION_DIR"/installs/todo.txt/install.sh

# editors
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling tern\n***"
source "$WORKSTATION_DIR"/installs/tern/install.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling emacs\n***"
source "$WORKSTATION_DIR"/installs/emacs/install.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling spacemacs\n***"
source "$WORKSTATION_DIR"/installs/spacemacs/install.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling vim\n***"
source "$WORKSTATION_DIR"/installs/vim/install.sh

# databases
#[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling mysql\n***"
#source "$WORKSTATION_DIR"/installs/mysql/install.sh

# backup
#[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling rclone\n***"
#source "$WORKSTATION_DIR"/installs/rclone/install.sh
#[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling megadown\n***"
#source "$WORKSTATION_DIR"/installs/megadown/install.sh

# version management tools
# git already installed above
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling grv\n***"
source "$WORKSTATION_DIR"/installs/grv/install.sh

# shell 
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling bat\n***"
source "$WORKSTATION_DIR"/installs/bat/install.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling fzf\n***"
source "$WORKSTATION_DIR"/installs/fzf/install.sh
# Jump is redondant with fasd (which is integrated with fzf)
# =todo= which is better? 
#[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling jump\n***"
#source "$WORKSTATION_DIR"/installs/jump/install.sh

# =todo= remove and remove bashd package
#[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstallin bashd\n***"
#source "$WORKSTATION_DIR"/installs/bashd/install.sh

# devops
#[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling minikube\n***"
#source "$WORKSTATION_DIR"/installs/minikube/install.sh

# We're set
echo -e "\nSourcing ~/.bashrc\n***"
source ~/.bashrc
echo -e "Station on orbit!\n***"
