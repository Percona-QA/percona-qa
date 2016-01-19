#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Simple script to compile earliest versions of PS5.7

if [ "${1}" == "" ]; then
  echo "This script requires one option: a directory name prefix (used in the resulting target directory). For example 'PS' or 'MS'"
  exit 1
fi

CURPATH=$(echo $PWD | sed 's|.*/||')

cd ..
rm -Rf ${CURPATH}_opt
rm -f /tmp/5.7_opt_build
cp -R ${CURPATH} ${CURPATH}_opt
cd ${CURPATH}_opt

### TEMPORARY HACK TO AVOID COMPILING TB (WHICH IS NOT READY YET)
rm -Rf ./plugin/tokudb-backup-plugin

cmake . -DWITH_ZLIB=system -DBUILD_CONFIG=mysql_release -DFEATURE_SET=community -DENABLE_DOWNLOADS=1 -DDOWNLOAD_BOOST=1 -DWITH_BOOST=/tmp -DWITH_SSL=system -DWITH_PAM=ON | tee /tmp/5.7_opt_build 
make | tee -a /tmp/5.7_opt_build
./scripts/make_binary_distribution | tee -a /tmp/5.7_opt_build
TAR_opt=`ls -1 *.tar.gz | head -n1`
if [ "${TAR_opt}" != "" ]; then
  DIR_opt=$(echo "${TAR_opt}" | sed 's|.tar.gz||')
  TAR_opt_new=$(echo "${1}-${TAR_opt}" | sed 's|.tar.gz|-opt.tar.gz|')
  DIR_opt_new=$(echo "${TAR_opt_new}" | sed 's|.tar.gz||')
  if [ "${DIR_opt}" != "" ]; then rm -Rf ../${DIR_opt}; fi
  if [ "${DIR_opt_new}" != "" ]; then rm -Rf ../${DIR_opt_new}; fi
  if [ "${TAR_opt_new}" != "" ]; then rm -Rf ../${TAR_opt_new}; fi
  mv ${TAR_opt} ../${TAR_opt_new}
  cd ..
  tar -xf ${TAR_opt_new}
  mv ${DIR_opt} ${DIR_opt_new}
  echo "Done! Now run;"
  echo "mv ../${DIR_opt_new} /sda"  # The script will end still in $PWD, hence we will need ../ (output only)
  rm -Rf ${CURPATH}_opt
  exit 0
else
  echo "There was some build issue... Have a nice day!"
  exit 1
fi
