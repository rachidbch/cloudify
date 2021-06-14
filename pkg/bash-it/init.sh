# Bash-it

# Bash-it install complains if no ~/bin/ is found
# =todo= Report Issue
WRKFY_DEBUG_MSG "Creating $HOME/bin directory"
if [[ ! -e ~/bin ]]; then
  mkdir ~/bin
elif [[ ! -d ~/bin ]]; then
  echo "FATAL: ~/bin already exists and isn\'nt a directory"
  exit 1
fi

# Bash-it complains if Bash-Completion is absent
WRKFY_DEBUG_MSG "Installing bash-completion"
sudo apt-get -q install bash-completion -y

# Clone bash-it
if [ -d ~/.bash_it ]; then
  WRKFY_DEBUG_MSG "Updating workify packages definitions"
  ( cd ~/.bash_it; git pull)
else
  WRKFY_DEBUG_MSG "Downloading worify packages definitions"
  git clone --depth=1 https://github.com/Bash-it/bash-it.git ~/.bash_it
  # this will backup current ~/.bashrc and create a new one.
  # [BUG] sourcing (instead of calling it as an executable) generates an error.
  # [TODO] report the bug

  WRKFY_DEBUG_MSG "Launching bash_it install script"
  chmod +x ~/.bash_it/install.sh
  # with '-n' option bash-it shouldn't overwrite ~/.bashrc (it shoudl be stowed from our dotfiles)
  ~/.bash_it/install.sh -n
fi

# Clone bash.d ( Not needed anymore as bash.d is now part of dotfiles)
# if [ -d ~/.bash.d ]; then
#     ( cd ~/.bash.d; git pull )
# else
#   git clone  "https://gitlab.com/mobilefirstcentury/bash-it.git"  ~/.bash.d
# fi

# # in .bashrc, set BASH_IT_CUSTOM to ~/.bash.d/ just before sourcing bash_it.sh
# # we should obtain something akin to:
# #  BASH_IT_CUSTOM="/home/rbc/.bash.d/"
# #  source "$BASH_IT"/bash_it.sh
# sed - i "/source \"\$BASH_IT\"\/bash_it.sh/i\BASH_IT_CUSTOM=\"\/home\/$USER\/.bash.d\/\""  ~/.bashrc

#source ~/.bashrc # to activate  bash_it
