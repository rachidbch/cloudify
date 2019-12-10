# global install pip and pip3
# python, python3, pip and pip3 should be the only executables installed globally
# everything else should be installed in user site or better in virtual envs

# install Pip3 before Pip2, otherwise pip will default to pip3 instead of pip2 (bug?)

# this will install /usr/local/bin/pip3
wget https://bootstrap.pypa.io/get-pip.py -O /tmp/get-pip.py
# without sudo -H, install generates an error
sudo -H python3 /tmp/get-pip.py

# this will install /usr/local/bin/pip (ie. pip2)
sudo -H python2  /tmp/get-pip.py
