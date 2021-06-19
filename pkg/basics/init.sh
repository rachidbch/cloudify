# Some stations come without proper locales
# On RackNerd VPS, I had a lot of " perl: warning: Setting locale failed." errors
# Some advise to be selective and install only needed locales. How?
WRKFY_APT_INSTALL language-pack-en-base

# Without software-propreties-common this no add-apt-repository ...
# Add a mini comment to explain other installs

WRKFY_APT_INSTALL apt-transport-https ca-certificates curl gnupg-agent software-properties-common bc 

# trash-cli is used by workify to safely delete files and directories 
WRKFY_APT_INSTALL trash-cli 

# Nice to have tooling 
WRKFY_APT_INSTALL tree procps jq rename pandoc moreutils 
