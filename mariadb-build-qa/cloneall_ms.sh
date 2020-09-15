#!/bin/bash
# Created by Roel Van de Paar, MariaDB

rm -Rf 5.5
rm -Rf 5.6
rm -Rf 5.7
rm -Rf 8.0
git clone --depth=1 --recurse-submodules -j8 --branch=5.5 https://github.com/mysql/mysql-server.git 5.5 &
git clone --depth=1 --recurse-submodules -j8 --branch=5.6 https://github.com/mysql/mysql-server.git 5.6 &
git clone --depth=1 --recurse-submodules -j8 --branch=5.7 https://github.com/mysql/mysql-server.git 5.7 &
git clone --depth=1 --recurse-submodules -j8 --branch=8.0 https://github.com/mysql/mysql-server.git 8.0 &
