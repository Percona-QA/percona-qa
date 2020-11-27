#!/bin/bash
# Created by Roel Van de Paar, MariaDB

if [[ "${1}" == "10."* ]]; then rm -Rf ${1}; fi
#git clone --depth=1 --recurse-submodules -j8 --branch=$1 https://github.com/MariaDB/server.git $1 &

# For full trees, use:
git clone --recurse-submodules -j8 --branch=$1 https://github.com/MariaDB/server.git $1 &
