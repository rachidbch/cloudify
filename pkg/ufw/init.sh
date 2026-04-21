#!/usr/bin/env bash
apt-get install -y ufw
sudo ufw allow OpenSSH
sudo ufw enable
