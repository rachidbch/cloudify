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


# Install packages
if [ -z "$1" ]; then
  for pkg in $(< ${PKGS_FILE}); do
    echo ${pkg%%*( )}
    [ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling ${pkg}\n***"
    source "$WORKSTATION_DIR"/pkg/${pkg%%*( )}/${PKG_INIT}                          # We use bash expansion to trim spaces at the end of the package name
  done
elif [[ "$1" == "ls" || "$1" == "list" ]]; then
  \ls "$WORKSTATION_DIR"/pkg
else
  pkg="$1"
  echo ${pkg%%*( )}
  [ -z "$WORKSTATION_DEBUG" ] || echo -e "\nInstalling ${pkg}\n***"
  source "$WORKSTATION_DIR"/pkg/${pkg%%*( )}/${PKG_INIT}                          # We use bash expansion to trim spaces at the end of the package name
fi

# Finish 
if [ "$1" != "ls" -a "$1" != "list" ]; then
 echo -e "\nNow please Source ~/.bashrc\n***"
 echo -e "Station on orbit!\n***"
fi
