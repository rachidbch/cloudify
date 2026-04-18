#!/usr/bin/env bash
# notes: release links
#   - latest()  Linux 64 : https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-x86_64.sh

# download bat deb in ~/workstation/install/deb
curl -LSs "https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-x86_64.sh" > miniconda3.sh

# install miniconda3
# shellcheck disable=SC1091 # file is created at runtime by curl on line above
source ./miniconda3.sh
