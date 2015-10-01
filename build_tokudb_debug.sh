#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

WORKDIR=/dev/shm/

cd ${WORKDIR}
mkdir PS56_TOKUDB_DBG
if [ ! -d ${WORKDIR}/PS56_TOKUDB_DBG ]; then
  echo "Something is wrong: tried creating \${WORKDIR}/PS56_TOKUDB_DBG (${WORKDIR}/PS56_TOKUDB_DBG), but the directory is not there. Please check WORKDIR setting in the script!"
  exit 1
fi
cd ${WORKDIR}/PS56_TOKUDB_DBG

git init .

git clone -b 5.6 https://github.com/percona/percona-server percona-server  
git clone https://github.com/percona/tokudb-engine tokudb-engine
git clone https://github.com/percona/perconaFT PerconaFT

ln -s ../../tokudb-engine/storage/tokudb percona-server/storage
ln -s ../../../PerconaFT tokudb-engine/storage/tokudb

mkdir percona-server-build
cd percona-server-build
cmake -DCMAKE_BUILD_TYPE=Debug -DCMAKE_INSTALL_PREFIX=../percona-server-install -DMYSQL_MAINTAINER_MODE=OFF ../percona-server
make install -j4

sed -i 's|mysql-5\.6\.|Percona-Server-5.6.|' CPackConfig.cmake  # Workaround for BLD-309
./scripts/make_binary_distribution

echo "Done! The last line above will show the location of the .tar.gz package!"
