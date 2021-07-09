UBUNTU_VER="$(lsb_release -r | cut -f2)"

# Python2 should always be accessible through `python` command

if [ -z "$(command -v "python" 2>&1)"  ]; then 
  echo "Installing python2 as python"
  [ -z "$(find /var/cache/apt/pkgcache.bin -mmin -60)" ] &&  sudo apt-get -q update
  pkg_apt_install python 
fi

## Python3 should always be accessible through `python3` command
if [ -z "$(command -v "python3" 2>&1)"  ]; then 
  echo "Installing python3 as python3"
  [ -z "$(find /var/cache/apt/pkgcache.bin -mmin -60)" ] &&  sudo apt-get -q update
  pkg_apt_install python3
fi

# On Ubuntu 16.04 official apt repo doesn't have Python 3.5+
# A lot of google pages point to adding jonathonf/python-3.6 but but jonathon has unpublished a lot of its packages
# The alternative is deadsnakes (see https://askubuntu.com/a/865569)
# =warning= 

# For unknown reason add-apt below failed with an error stating that the public KEY wasn't found
# I had to manually:
# 1. Go to https://launchpad.net/~deadsnakes/+archive/ubuntu/ppa
# 2. Find the Signing key fingerprint of the ppa  
# 3. Import the key with
#    $ gpg --keyserver keyserver.ubuntu.com --recv-keys F23C5A6CF475977595C89F51BA6932366A755776
# 5. Add the public the key to Ubunut apt trusted keys database
#    $ gpg --export --armor  F23C5A6CF475977595C89F51BA6932366A755776 | sudo apt-key add -
# 6. And then only proceed to add the apt repository and apt update
if (( $(echo "$UBUNTU_VER <= 16.04" | bc -l ))); then
  if [ -z "$(command -v "python3.6" 2>&1)"  ]; then 
    echo "Doing strange stuff to install python on Ubuntu 16.04-"

    pkg_apt_repository "deadsnakes/ppa"

    pkg_apt_install python3.6 

    # Set python3.6 as the default python3
    sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.5 1
    sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.6 2
    # =warning= If this doesn't do the job, select manually the alternative with:
    # $ sudo update-alternatives --config python3


  fi
fi

# Install pip2 as it python3.6 pkg comes without it
if ! python2 -m pip &>/dev/null; then 
  echo "Installing pip2"
  curl https://bootstrap.pypa.io/get-pip.py | sudo python2
fi

# Install pip3.6 as it python3.6 pkg comes without it
if ! python3 -m pip &>/dev/null; then 
  echo "Installing pip3"
  curl https://bootstrap.pypa.io/get-pip.py | sudo python3
fi

#if ! python2 -m venv &>/dev/null; then 
#  echo "Installing python2 venv"
#  python2 -m pip install virtualenv 
#fi

if ! python3 -m venv &>/dev/null; then 
  echo "Installing python3.6-venv"
  # Without this, `pipx install pycowsay' fails
  # Don't even ask me why ...   Python is just a mess...
  pkg_apt_install python3.6-venv 
fi

if ! python3 -m argcomplete &>/dev/null; then 
  echo "Installing argcomplete"
  # Don't ask about this one neither. Witout python3.6 complains about the module absence
  # I use sudo (which is not recommended), because I want the module "available globally" for 3.6, but the truth is I don't understand what I'm doing :(
  # So far, so good, ...
  # sudo -H pip3 install argcomplete
  # Most probably I shoud have done:
  
  python3 -m pip install argcomplete
  # =todo= Try it on a fresh install 
fi

# echo "Installing python3-distutils"
# =todo= The following package install fails on 16.04.06 LTS. As it was a workaround for the problem below, try to found out what to do with it!
# without this, following pip3 install [[https://github.com/pypa/pip/issues/5367#issuecomment-387354705][fails]]
#sudo apt-get -q install python3-distutils -y


