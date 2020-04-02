#!/bin/bash
# Created by Roel Van de Paar, MariaDB

git clone --depth=1 --recurse-submodules -j8 --branch=$1 https://github.com/MariaDB/server.git $1 &
