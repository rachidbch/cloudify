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

  git clone https://github.com/pyenv/pyenv.git ~/.pyenv

  # enable ~/.bash.d/available/pyenv.plugin
  # install virtualenv plugin  
  git clone https://github.com/pyenv/pyenv-virtualenv.git ~/.pyenv/plugins/pyenv-virtualenv
  # we prefer to not install pyenv virtualenv autoactivation feature. 
fi
