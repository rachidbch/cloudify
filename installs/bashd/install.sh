
# clone bash-it
if [ -d ~/.bash_it ]; then
    ( cd ~/.bash_it; git pull)
else
    git clone --depth=1 https://github.com/Bash-it/bash-it.git ~/.bash_it
    # this will create backup current ~/.bashrc and create a new one.
    # [BUG] sourcing (instead of calling it as an executable) generates an error.
    # [TODO] report the bug
    chmod +x ~/.bash_it/install.sh
    ~/.bash_it/install.sh
fi


if [ -d ~/.bash.d ]; then
    ( cd ~/.bash.d; git pull )
else
  git clone  "https://gitlab.com/mobilefirstcentury/bash-it.git"  ~/.bash.d
fi

# in .bashrc, set BASH_IT_CUSTOM to ~/.bash.d/ just before sourcing bash_it.sh
# we should obtain something akin to:
#  BASH_IT_CUSTOM="/home/rbc/.bash.d/"
#  source "$BASH_IT"/bash_it.sh
sed - i "/source \"\$BASH_IT\"\/bash_it.sh/i\BASH_IT_CUSTOM=\"\/home\/$USER\/.bash.d\/\""  ~/.bashrc

source ~/.bashrc # to activate  bash_it
