# Download MariaDB source .tar.gz and untar
# Then clone following repos into same directory where unpacked MariaDB
#git clone https://github.com/percona/Percona-TokuBackup.git
#git clone https://github.com/percona/tokudb-backup-plugin.git 

# Then just run this script and wait.

# Based ON -> https://mariadb.atlassian.net/browse/MDEV-8843

set -e
pushd tokudb-backup-plugin
rm -rf backup
ln -s ../Percona-TokuBackup/backup
popd
pushd mariadb-10.0.20/plugin
if [ -d tokudb-backup-plugin ] ; then rm tokudb-backup-plugin; fi
rm -rf tokudb-backup-plugin
ln -s ../../tokudb-backup-plugin
popd
rm -rf build install
mkdir build install
pushd build
cmake -DCMAKE_BUILD_TYPE=Debug -DCMAKE_INSTALL_PREFIX=../install -DMYSQL_MAINTAINER_MODE=OFF ../mariadb-10.0.20
make -j8 install
popd
