#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Simple script to compile earliest versions of PS5.7

if [ "${1}" == "" ]; then
  echo "This script requires one option: a directory name prefix (used in the resulting target directory). For example 'PS' or 'MS'"
  exit 1
fi

CURPATH=$(echo $PWD | sed 's|.*/||')

cd ..
rm -Rf ${CURPATH}_dbg
rm -f /tmp/5.7_debug_build
cp -R ${CURPATH} ${CURPATH}_dbg
cd ${CURPATH}_dbg

### TEMPORARY HACK TO AVOID COMPILING TB (WHICH IS NOT READY YET)
rm -Rf ./plugin/tokudb-backup-plugin

cmake . -DWITH_ZLIB=system -DCMAKE_BUILD_TYPE=Debug -DBUILD_CONFIG=mysql_release -DFEATURE_SET=community -DDEBUG_EXTNAME=OFF -DENABLE_DOWNLOADS=1 -DDOWNLOAD_BOOST=1 -DWITH_BOOST=/tmp -DWITH_SSL=system | tee /tmp/5.7_debug_build
make | tee -a /tmp/5.7_debug_build
./scripts/make_binary_distribution | tee -a /tmp/5.7_debug_build
TAR_dbg=`ls -1 *.tar.gz | head -n1`
if [ "$TAR_dbg}" != "" ]; then
  DIR_dbg=$(echo "${TAR_dbg}" | sed 's|.tar.gz||')
  TAR_dbg_new=$(echo "${1}-${TAR_dbg}" | sed 's|.tar.gz|-debug.tar.gz|')
  DIR_dbg_new=$(echo "${TAR_dbg_new}" | sed 's|.tar.gz||')
  if [ "${DIR_dbg}" != "" ]; then rm -Rf ../${DIR_dbg}; fi
  if [ "${DIR_dbg_new}" != "" ]; then rm -Rf ../${DIR_dbg_new}; fi
  if [ "${TAR_dbg_new}" != "" ]; then rm -Rf ../${TAR_dbg_new}; fi
  mv ${TAR_dbg} ../${TAR_dbg_new}
  cd ..
  tar -xf ${TAR_dbg_new}
  mv ${DIR_dbg} ${DIR_dbg_new}
  echo "Done! Now run;"
  echo "mv ../${DIR_dbg_new} /sda"  # The script will end still in $PWD, hence we will need ../ (output only)
  rm -Rf ${CURPATH}_dbg
  exit 0
else
  echo "There was some build issue... Have a nice day!"
  exit 1
fi
