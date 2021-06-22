# Bash-it package

## # Bash-it complains if bash-completion is absent
pkg_depends bash-completion

# Bash-it install complains if no ~/bin/ is found
# =todo= Report Issue
if [[ ! -e "$HOME"/bin ]]; then
  mkdir "$HOME"/bin
elif [[ ! -d "$HOME"/bin ]]; then
  echo "FATAL: ~/bin already exists and isn\'nt a directory"
  exit 1
fi

# Clone bash-it repo
if [ -d ~/.bash_it ]; then
  PKG_DEBUG_LN "Updating cloudify packages definitions"
  ( cd "$HOME"/.bash_it; git pull)
else
  PKG_DEBUG_LN "Downloading cloudify packages definitions"
  git clone --depth=1 https://github.com/Bash-it/bash-it.git ~/.bash_it

  PKG_DEBUG_LN "Launching bash_it install script"
  chmod +x ~/.bash_it/install.sh
  # with '-n' option bash-it shouldn't overwrite ~/.bashrc (it shoudl be stowed from our dotfiles)
  "$HOME"/.bash_it/install.sh -n
fi

# Add environment variables and aliaes required to  bash-it in ~/.bashrc
# In .bashrc, we set BASH_IT_CUSTOM to ~/.bash.d/ just before sourcing bash_it.sh

# Update env related setup in ~/.bashrc
pkg_in_startuprc \
    '## BASH_IT SETUP'\
    'export BASH_IT="$HOME/.bash_it"'\
    'export BASH_IT_THEME="bobby\"'\
    'export SCM_CHECK=true'\
    'export SHORT_HOSTNAME=$(hostname -s)'\
    'export BASH_IT_RELOAD_LEGACY=1'\
    '[[ -d "$HOME/.bash.d" ]] && export BASH_IT_CUSTOM="$HOME/.bash.d" || unset BASH_IT_CUSTOM'\
    'source $HOME/.bash_it/bash_it.sh' 

# WARNING: before sourcing ~/.bashrc, directory defined by BASH_IT_CUSTOM (by default ~/.bashd.d) must be populated w/ mobilefirstcentury/bash-it.git   
# NOTE: ~/.bash.d content is part of MFC dotfiles and can be setup with stow! 

# if [ -d ~/.bash.d ]; then
#     ( cd ~/.bash.d; git pull )
# else
#   git clone  "https://gitlab.com/mobilefirstcentury/bash-it.git"  ~/.bash.d
# fi

