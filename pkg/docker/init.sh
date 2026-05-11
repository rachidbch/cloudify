#!/usr/bin/env bash
# Docker CE installation
# Docker Compose v2 is included as the docker-compose-plugin ('docker compose')

pkg_apt_install ca-certificates curl

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker's apt repository (DEB822 format)
tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
pkg_apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

msg "Docker version installed"
docker -v

msg "Adding $USER to 'docker' group"
sudo usermod -aG docker "$USER"

msg "Warning: Ensure $USER is in 'docker' group"
msg "$ newgrp docker"
msg "$ newgrp $USER"
msg "Then test docker installation"
msg "$ docker run hello-world"
