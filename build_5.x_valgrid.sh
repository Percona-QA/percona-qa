#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Simple script to compile earliest versions of PS5.7

if [ "${1}" == "" ]; then
  echo "This script requires one option: a directory name prefix (used in the resulting target directory). For example 'PS' or 'MS'"
  exit 1
fi

CURPATH=$(echo $PWD | sed 's|.*/||')

cd ..
rm -Rf ${CURPATH}_val
rm -f /tmp/5.7_valgrind_build
cp -R ${CURPATH} ${CURPATH}_val
cd ${CURPATH}_val

### TEMPORARY HACK TO AVOID COMPILING TB (WHICH IS NOT READY YET)
rm -Rf ./plugin/tokudb-backup-plugin

cmake . -DWITH_ZLIB=system -DCMAKE_BUILD_TYPE=Debug -DBUILD_CONFIG=mysql_release -DFEATURE_SET=community -DDEBUG_EXTNAME=OFF -DWITH_EMBEDDED_SERVER=OFF -DENABLE_DOWNLOADS=1 -DDOWNLOAD_BOOST=1 -DWITH_BOOST=/tmp -DWITH_SSL=system -DWITH_PAM=ON -DWITH_VALGRIND=ON -DWITH_ASAN=ON | tee /tmp/5.7_valgrind_build
make -j5 | tee -a /tmp/5.7_valgrind_build
./scripts/make_binary_distribution | tee -a /tmp/5.7_valgrind_build
TAR_val=`ls -1 *.tar.gz | head -n1`
if [ "$TAR_val}" != "" ]; then
  DIR_val=$(echo "${TAR_val}" | sed 's|.tar.gz||')
  TAR_val_new=$(echo "${1}-${TAR_val}" | sed 's|.tar.gz|-val.tar.gz|')
  DIR_val_new=$(echo "${TAR_val_new}" | sed 's|.tar.gz||')
  if [ "${DIR_val}" != "" ]; then rm -Rf ../${DIR_val}; fi
  if [ "${DIR_val_new}" != "" ]; then rm -Rf ../${DIR_val_new}; fi
  if [ "${TAR_val_new}" != "" ]; then rm -Rf ../${TAR_val_new}; fi
  mv ${TAR_val} ../${TAR_val_new}
  cd ..
  tar -xf ${TAR_val_new}
  mv ${DIR_val} ${DIR_val_new}
  echo "Done! Now run;"
  echo "mv ../${DIR_val_new} /sda"  # The script will end still in $PWD, hence we will need ../ (output only)
  #rm -Rf ${CURPATH}_val  # Best not to delete it; this way gdb debugging is better quality as source will be available!
  exit 0
else
  echo "There was some build issue... Have a nice day!"
  exit 1
fi
