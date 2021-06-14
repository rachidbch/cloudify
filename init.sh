# Workstation installation
# =warning= this script must be SOURCED and not executed  (otherwise environment modifcations, like aliases, won't persist after exectution)
# =todo= Modify the script so it can be executed: all environment variables and aliases that must persist be set by bash-it 

# DEBUG or NOT
WORKSTATION_DEBUG=true

# Local Configuration variables

WORKSTATION_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

LOCAL_TMP=~/tmp/
[ -d "$LOCAL_TMP" ] || mkdir -p "$LOCAL_TMP"
export EDITOR=vim                           # If an editor is needed during install 

LOCAL_BIN=~/.local/bin
[ -d "$LOCAL_BIN" ] || mkdir -p "$LOCAL_BIN"
#set PATH=$PATH:"$LOCAL_BIN"

# Are we on Android Termux or Linux station?
if [ ! -z "$(pgrep -f com.termux)" ]; then
    PKGS_FILE=${WORKSTATION_DIR}/termux.packages
    PKG_INIT="termux.init.sh"
else
    PKGS_FILE=${WORKSTATION_DIR}/station.packages
    PKG_INIT="init.sh"
fi

function printHelp(){
cat << EOF
usage: cloudify:                    print help
       cloudify help:               print help  
       cloudify ls|list:            list installable packages 
       cloudify ls|list enabled:    list enabled packages 
       cloudify i <pkg>             install package
       cloudify i enabled           install enabled in termux|station.packages
       cloudify u <pkg>             uninstall package
EOF
}

function printDone() {
  echo -e "\nNow please Source ~/.bashrc\n***"
  echo -e "Station on orbit!\n***"
}

# Install packages
if [[ -z "$1" || "$1" == "help"]] ; then
  printHelp
elif [[ ( "$1" == "ls" || "$1" == "list" ) && "$2" == "enabled" ]]; then
  for pkg in $(< ${PKGS_FILE}); do
    echo ${pkg%%*( )}
  done
elif [[ ( "$1" == "ls" || "$1" == "list" ) && ( -z "$2" || "$2" == "all" ) ]]; then
  \ls "$WORKSTATION_DIR"/pkg
elif [[ "$1" == "i" &&  "$2" == "enabled" ]]; then
  for pkg in $(< ${PKGS_FILE}); do
    echo ${pkg%%*( )}
    [ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling ${pkg}\n***"
    source "$WORKSTATION_DIR"/pkg/${pkg%%*( )}/${PKG_INIT}                          # We use bash expansion to trim spaces at the end of the package name
  done
  printDone
elif [[ "$1" == "i" &&  ! -z "$2" ]]; then
  pkg="$1"
  echo ${pkg%%*( )}
  [ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling ${pkg}\n***"
  source "$WORKSTATION_DIR"/pkg/${pkg%%*( )}/${PKG_INIT}                          # We use bash expansion to trim spaces at the end of the package name
  printDone
else
  printHelp
fi

