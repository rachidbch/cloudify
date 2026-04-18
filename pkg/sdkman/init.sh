#!/bin/bash
set -e

# SDKMAN!
# Version manager for java world
# ====

echo "installing sdk ..."

# save bashrc
[[ -f ~/.bashrc ]] && cp -f ~/.bashrc ~/.bashrc.bak

# restore original bashrc on exit
# shellcheck disable=SC2317 # function is called indirectly via trap below
function restore_bashrc {
    cp -f ~/.bashrc.bak ~/.bashrc
    rm  ~/.bashrc.bak
}
trap restore_bashrc EXIT

# do install
curl -s "https://get.sdkman.io" | bash        # there's no way to prevent this from modifying bashrc
                                              # so bashrc is saved before hand and restored on exit

# activate sdkman for current session (permanent activation is done in ~/.bash.d/)
# shellcheck disable=SC1091 # file is created at runtime by sdkman installer on line above
source "$HOME/.sdkman/bin/sdkman-init.sh" #activating initialization shell script
sdk install java
RESULT=$?
echo "sdkman installation done!"
exit $RESULT
