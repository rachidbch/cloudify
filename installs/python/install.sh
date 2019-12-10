
# Python2 should always be accessible through `python` command
if [ -z "$(command -v "python" 2>&1)"  ]; then sudo apt install python; fi
# Maybe we don't have python3
if [ -z "$(command -v "python3" 2>&1)"  ]; then sudo apt install python3; fi

# =todo= The following package install fails on 16.04.06 LTS. As it was a workaround for the problem below, try to found out what to do with it!
# without this, following pip3 install [[https://github.com/pypa/pip/issues/5367#issuecomment-387354705][fails]]
#sudo apt install python3-distutils
