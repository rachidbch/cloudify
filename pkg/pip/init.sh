# global install pip and pip3
# python, python3, pip and pip3 should be the only executables installed globally
# everything else should be installed in user site or better in virtual envs

# install Pip3 before Pip2, otherwise pip will default to pip3 instead of pip2 (bug?)

# this will install /usr/local/bin/pip3
if [ -z $(which pip3) ]; then
  PKG_DEBUG "Installing pip3"
  wget -nv https://bootstrap.pypa.io/get-pip.py -O /tmp/get-pip.py
  # without sudo -H, install generates an error
  PKG_DEBUG "Executing pip install script with pyhton3"
  sudo -H python3 /tmp/get-pip.py
  rm /tmp/get-pip.py
fi
if [ -z $(which pip2) ]; then
  PKG_DEBUG "Installing pip2"
  wget -nv https://bootstrap.pypa.io/pip/2.7/get-pip.py  -O /tmp/get-pip.py
  # this will install /usr/local/bin/pip (ie. pip2)
  PKG_DEBUG "Executing pip install script with pyhton2"
  sudo -H python2  /tmp/get-pip.py
  rm /tmp/get-pip.py
fi
