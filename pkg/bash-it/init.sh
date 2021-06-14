# Bash-it

# Bash-it install complains if no ~/bin/ is found
# =todo= Report Issue
WRKFY_DEBUG_MSG_NEWLINE "Creating $HOME/bin directory"
if [[ ! -e ~/bin ]]; then
  mkdir ~/bin
elif [[ ! -d ~/bin ]]; then
  echo "FATAL: ~/bin already exists and isn\'nt a directory"
  exit 1
fi

# Bash-it complains if Bash-Completion is absent
WRKFY_DEBUG_MSG_NEWLINE "Installing bash-completion"
dpkg -l bash-completions |& grep -q "^ii  bash-completion" && sudo apt-get -q install bash-completion -y

# Clone bash-it
if [ -d ~/.bash_it ]; then
  WRKFY_DEBUG_MSG_NEWLINE "Updating workify packages definitions"
  ( cd ~/.bash_it; git pull)
else
  WRKFY_DEBUG_MSG_NEWLINE "Downloading workify packages definitions"
  git clone --depth=1 https://github.com/Bash-it/bash-it.git ~/.bash_it
  # this will backup current ~/.bashrc and create a new one.
  # [BUG] sourcing (instead of calling it as an executable) generates an error.
  # [TODO] report the bug

  WRKFY_DEBUG_MSG_NEWLINE "Launching bash_it install script"
  chmod +x ~/.bash_it/install.sh
  # with '-n' option bash-it shouldn't overwrite ~/.bashrc (it shoudl be stowed from our dotfiles)
  ~/.bash_it/install.sh -n
fi


# Lines to add to bashrc to persist environment variables and aliases
WRKFY_DEBUG_MSG_NEWLINE "List environment setup"
#WRKFY_PKG_ENV=( "## BASH_IT ENV SETUP" "BASH_IT_CUSTOM=\"\$HOME\/.bash.d\"" "source \$HOME\/.bash_it\/bash_it.sh" )
WRKFY_PKG_ENV=( '## BASH_IT ENV SETUP' 'BASH_IT_CUSTOM="$HOME/.bash.d"' 'source $HOME/.bash_it/bash_it.sh' )




WRKFY_PKG_ENV=$(echo $WRKFY_PKG_ENV | sed 's/\//\\\//g')

# Reserve workit space in bashrc
WRKFY_DEBUG_MSG_NEWLINE "Reserve Workify space inside bashrc"
grep -qFx "# WORKIT ENV START" ~/.bashrc || echo -e "# WORKIT ENV START\n# WORKIT ENV END"  >> ~/.bashrc

# Remove previous pkg setup
WRKFY_DEBUG_MSG_NEWLINE "Remove existing pkg setup if any"
for wrkfy_line in "${WRKFY_PKG_ENV[@]}"; do
  WRKFY_DEBUG_MSG "Remove line: $wrkfy_line"
  sed -in "/$wrkfy_line/d" ~/.bashrc
  WRKFY_DEBUG_MSG "----"
  WRKFY_DEBUG_MSG "What's in there in bashrc?"
  tail ~/.bashrc
  echo 
done;



# Insert bash-it env
WRKFY_DEBUG_MSG_NEWLINE "Inserting pkg setup"
for wrkfy_line in "${WRKFY_PKG_ENV[@]}"; do
  WRKFY_DEBUG_MSG "Inserting line: $wrkfy_line"
  sed -in "/# WORKIT ENV END/i $wrkfy_line" ~/.bashrc
  WRKFY_DEBUG_MSG "----"
  WRKFY_DEBUG_MSG "What's in there in bashrc?"
  tail ~/.bashrc
  echo
done;


# Clone bash.d ( Not needed anymore as bash.d is now part of dotfiles)
# if [ -d ~/.bash.d ]; then
#     ( cd ~/.bash.d; git pull )
# else
#   git clone  "https://gitlab.com/mobilefirstcentury/bash-it.git"  ~/.bash.d
# fi

# # in .bashrc, set BASH_IT_CUSTOM to ~/.bash.d/ just before sourcing bash_it.sh
# # we should obtain something akin to:
# #  BASH_IT_CUSTOM="/home/rbc/.bash.d/"
# #  source "$bash_it"/bash_it.sh
# sed - i "/source \"\$BASH_IT\"\/bash_it.sh/i\BASH_IT_CUSTOM=\"\/home\/$USER\/.bash.d\/\""  ~/.bashrc

#source ~/.bashrc # to activate  bash_it
