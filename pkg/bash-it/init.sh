# Bash-it package

# Bash-it install complains if no ~/bin/ is found
# =todo= Report Issue
if [[ ! -e ~/bin ]]; then
  mkdir ~/bin
elif [[ ! -d ~/bin ]]; then
  echo "FATAL: ~/bin already exists and isn\'nt a directory"
  exit 1
fi

## 
## # Bash-it complains if Bash-Completion is absent
## dpkg -l bash-completions |& grep -q "^ii  bash-completion" || sudo apt-get -q install bash-completion -y


# Clone bash-it repo
if [ -d ~/.bash_it ]; then
  WRKFY_DEBUG_MSG_NEWLINE "Updating workify packages definitions"
  ( cd ~/.bash_it; git pull)
else

  WRKFY_DEBUG_MSG_NEWLINE "Downloading workify packages definitions"
  git clone --depth=1 https://github.com/Bash-it/bash-it.git ~/.bash_it

  WRKFY_DEBUG_MSG_NEWLINE "Launching bash_it install script"
  chmod +x ~/.bash_it/install.sh
  # with '-n' option bash-it shouldn't overwrite ~/.bashrc (it shoudl be stowed from our dotfiles)
  ~/.bash_it/install.sh -n
fi


# Add environment variables and aliaes required to  bash-it in ~/.bashrc
# In .bashrc, we set BASH_IT_CUSTOM to ~/.bash.d/ just before sourcing bash_it.sh

# # We want something akin to: 
#
#   > ## BASH_IT ENV SETUP
#   > BASH_IT_CUSTOM="/home/rbc/.bash.d/"
#   > source "$bash_it"/bash_it.sh

WRKFY_PKG_ENV=( '## BASH_IT ENV SETUP' 'export BASH_IT="$HOME/.bash_it"' 'export BASH_IT_THEME="bobby\"' 'export SCM_CHECK=true' 'export SHORT_HOSTNAME=$(hostname -s)' 'export BASH_IT_RELOAD_LEGACY=1' '[[ -d "$HOME/.bash.d" ]] && export BASH_IT_CUSTOM="$HOME/.bash.d" || unset BASH_IT_CUSTOM' 'source $HOME/.bash_it/bash_it.sh' )

# This function does the work of updating the values above in ~/.bashrc
wrkfy_pkg_startup 


# WARNING: before sourcing ~/.bashrc, directory defined by BASH_IT_CUSTOM (by default ~/.bashd.d) must be populated w/ mobilefirstcentury/bash-it.git   
# NOTE: ~/.bash.d content is part of MFC dotfiles and can be setup with stow! 
# if [ -d ~/.bash.d ]; then
#     ( cd ~/.bash.d; git pull )
# else
#   git clone  "https://gitlab.com/mobilefirstcentury/bash-it.git"  ~/.bash.d
# fi

