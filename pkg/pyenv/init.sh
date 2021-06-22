# Pyenv installation
# Pyenv is an nvm for python. It allows you to switch dynamically currently active python version 

# Bug workaround
# bug: [[https://github.com/conda/conda/issues/6018][bug in python3]]
#   this bug inserts user site packages path in sys.path. 
#   system user site packages then leaks in conda environments.
#   to prevent that: $ export PYTHONNOUSERSITE=True
export PYENV_VIRTUALENV_DISABLE_PROMPT=1

# prevent  pyenv activate <version> to modify prompt (only pyenv activate <env> should be visible in prompt):
export PYTHONNOUSERSITE=True


# install pyenv
if [ ! -d ~/.pyenv ]; then
  PKG_DEBUG_LN "Cloning pyenv repo in ~/.pyenv"
  git clone https://github.com/pyenv/pyenv.git "$HOME"/.pyenv

  # enable ~/.bash.d/available/pyenv.plugin
  # install virtualenv plugin  
  PKG_DEBUG_LN "Adding pyenv-virtualenv plugin"
  git clone https://github.com/pyenv/pyenv-virtualenv.git ~/.pyenv/plugins/pyenv-virtualenv
  # we prefer to not install pyenv virtualenv autoactivation feature. 
fi

export PYENV_ROOT="$HOME"/.pyenv
[[ ":${PATH}:" != *":${PYENV_ROOT}/bin:"* ]] && export PATH="${PYENV_ROOT}/bin:${PATH}"
[[ ":${PATH}:" != *":${PYENV_ROOT}/shims:"* ]] && export PATH="${PYENV_ROOT}/shims:${PATH}"
eval "$(pyenv init -)"  &> /dev/null

# This function does the work of updating the values above in ~/.bashrc
pkg_in_startuprc \
    '## PYENV ENV SETUP'\
    'export PYENV_VIRTUALENV_DISABLE_PROMPT=1'\
    'export PYTHONNOUSERSITE=True' 'export PYENV_ROOT="$HOME"/.pyenv'\
    '[[ ":$PATH:" != *":$PYENV_ROOT/bin:"* ]] && export PATH="$PYENV_ROOT/bin:$PATH"'\
    '[[ ":$PATH:" != *":$PYENV_ROOT/shims:"* ]] && export PATH="$PYENV_ROOT/shims:$PATH"'\
    'eval "$(pyenv init -)" &> /dev/null' 

