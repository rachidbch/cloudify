# Workstation installation
# =warning= this script must be SOURCED and not executed  (otherwise environment modifcations, like aliases, won't persist after exectution)

# DEBUG or NOT
WORKSTATION_DEBUG=true

# Local Configuration variables
[ -z "$WORKSTATION_DEBUG" ] || echo -e "Setting Exports...\n***"
WORKSTATION_DIR=~/cloudstation/

LOCAL_TMP=~/tmp/
[ -d "$LOCAL_TMP" ] || mkdir -p "$LOCAL_TMP"
export EDITOR=vim                           # If an editor is needed during install 

LOCAL_BIN=~/.local/bin
[ -d "$LOCAL_BIN" ] || mkdir -p "$LOCAL_BIN"
#set PATH=$PATH:"$LOCAL_BIN"

# Fundamental stuff
## basic apt packages
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling basics\n***"
source "$WORKSTATION_DIR"/pkg/basics/init.sh

## Python
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling python\n***"
source "$WORKSTATION_DIR"/pkg/python/init.sh

## Version management tools
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling git\n***"
source "$WORKSTATION_DIR"/pkg/git/init.sh


## Import and setup our dotfiles
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling dotfiles\n***"
source "$WORKSTATION_DIR"/pkg/dotfiles/init.sh

## bash  (bash-it install has a flag raised to not touch ~/.bashrc has it has already been set by dotfiles package above)
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling bash-it\n***"
source "$WORKSTATION_DIR"/pkg/bash-it/init.sh


# Miscelaneous softwares

## ssh management
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling mosh\n***"
source "$WORKSTATION_DIR"/pkg/mosh/init.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling tmux\n***"
source "$WORKSTATION_DIR"/pkg/tmux/init.sh

## programming languages
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling pip\n***"
source "$WORKSTATION_DIR"/pkg/pip/init.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling nvm\n***"
source "$WORKSTATION_DIR"/pkg/nvm/init.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling go\n***"
source "$WORKSTATION_DIR"/pkg/go/init.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\n\nInstalling php\n***"
source "$WORKSTATION_DIR"/pkg/php/init.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling ruby\n***"
source "$WORKSTATION_DIR"/pkg/ruby/init.sh
###[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling miniconda3\n***"
###source "$WORKSTATION_DIR"/pkg/miniconda3/init.sh

## Todo_txt 
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling toto.txt\n***"
source "$WORKSTATION_DIR"/pkg/todo.txt/init.sh

## editors
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling tern\n***"
source "$WORKSTATION_DIR"/pkg/tern/init.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling emacs\n***"
source "$WORKSTATION_DIR"/pkg/emacs/init.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling spacemacs\n***"
source "$WORKSTATION_DIR"/pkg/spacemacs/init.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling vim\n***"
source "$WORKSTATION_DIR"/pkg/vim/init.sh


## python related
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling virtualenv\n***"
source "$WORKSTATION_DIR"/pkg/virtualenv/init.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling pyenv\n***"
source "$WORKSTATION_DIR"/pkg/pyenv/init.sh


## databases
###[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling mysql\n***"
###source "$WORKSTATION_DIR"/pkg/mysql/init.sh

## backup
###[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling rclone\n***"
##source "$WORKSTATION_DIR"/pkg/rclone/init.sh
##[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling megadown\n***"
##source "$WORKSTATION_DIR"/pkg/megadown/init.sh

## version management tools (git already installed above)
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling grv\n***"
source "$WORKSTATION_DIR"/pkg/grv/init.sh

## shell 
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling fasd\n***"
source "$WORKSTATION_DIR"/pkg/fasd/init.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling fzf\n***"
source "$WORKSTATION_DIR"/pkg/fzf/init.sh
[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling bat\n***"
source "$WORKSTATION_DIR"/pkg/bat/init.sh
### Jump is redondant with fasd (which is integrated with fzf) ### =todo= which is better? 
###[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling jump\n***"
###source "$WORKSTATION_DIR"/pkg/jump/init.sh

## devops
###[ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling minikube\n***"
###source "$WORKSTATION_DIR"/pkg/minikube/init.sh

# Finish 
echo -e "\nSourcing ~/.bashrc\n***"
source ~/.bashrc
echo -e "Station on orbit!\n***"
