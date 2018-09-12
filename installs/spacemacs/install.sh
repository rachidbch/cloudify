SPACEMACS
=========

# emacs install
sudo add-apt-repository ppa:kelleyk/emacs
sudo apt update
sudo apt install emacs26-nox   #non-X version

# spacemacs install
git clone https://github.com/syl20bnr/spacemacs ~/.emacs.d
git clone https://gitlab.com/rachidbch/spacemacs.git ~/.spacemacs.d

mv ~/.emacs.d/private ~/.spacemacs.d/
ln -s ~/.spacemacs.d/private ~/.emacs.d/private


# install some private layers
git clone https://github.com/venmos/w3m-layer.git ~/.spacemacs.d/private/w3m

# spacemacs bugs workarounds

# 1. missing layers dir
mkdir ~/.spacemacs.d/layers/

# 2. ac-ispell package bug: see https://github.com/syl20bnr/spacemacs/issues/11095 
git clone  https://github.com/syohex/emacs-ac-ispell.git ~/.spacemacs.d/private/emacs-ac-ispell
# install package manually in spacemacs: SPC SPC package-install-file ~/.spacemacs.d/private/emacs-ac-ispell          ;; [TODO] automate

# 3. yas snippets dirs warning: see https://github.com/syl20bnr/spacemacs/issues/10316
# simply create an empty `snippets` directory in path indicated by warning message
mkdir ~/.spacemacs.d/snippets/

