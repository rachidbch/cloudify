
# Python2 should always be accessible through `python` command
if [ -z "$(command -v "python" 2>&1)"  ]; then sudo apt install python; fi
# Maybe we don't have python3
if [ -z "$(command -v "python3" 2>&1)"  ]; then sudo apt install python3; fi

# without this, following pip3 install [[https://github.com/pypa/pip/issues/5367#issuecomment-387354705][fails]]
$ sudo apt install python3-distutils
