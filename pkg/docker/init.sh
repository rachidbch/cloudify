# Docker CE installation
# Docker Compose v2 is included as a plugin in docker-ce-cli ('docker compose')

pkg_apt_install apt-transport-https ca-certificates curl gnupg-agent software-properties-common

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

pkg_apt_install docker-ce docker-ce-cli containerd.io

msg "Docker version installed"
docker -v

msg "Adding $USER to 'docker' group"
sudo usermod -aG docker "$USER"

msg "Warning: Ensure $USER is in 'docker' group"
msg "$ newgrp docker"
msg "$ newgrp $USER"
msg "Then test docker installation"
msg "$ docker run hello-world"
