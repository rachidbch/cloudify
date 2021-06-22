# Some stations come without proper locales
# On RackNerd VPS, I had a lot of " perl: warning: Setting locale failed." errors
# Some advise to be selective and install only needed locales. How?
pkg_depends language-pack-en-base

# Without software-propreties-common this no add-apt-repository ...
# Add a mini comment to explain other installs

pkg_depends apt-transport-https ca-certificates curl gnupg-agent software-properties-common bc build-essential 

# trash-cli is used by cloudify to safely delete files and directories 
pkg_depends trash-cli 

# Nice to have tooling 
pkg_depends tree procps jq rename pandoc moreutils silversearcher-ag mosh
