
# tout d'abord scripter la configuration de pyenv pour avoir deux environements virtuels canoniques python2 et python3
# i.e. repliquer la configuration pyenv versions de cloudstation
pyenv virtualenv python3 snipster
pyenv activate snipster
(cd git && pip install snipster)
pyenv deactivate

# from now on, snipster will be launched with pyenv-exec snipster snipster
alias snipster="pyenv-exec snipster snipster"
