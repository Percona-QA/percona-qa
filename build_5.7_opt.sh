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
cmake . -DBUILD_CONFIG=mysql_release -DFEATURE_SET=community -DENABLE_DOWNLOADS=1 -DDOWNLOAD_BOOST=1 -DWITH_BOOST=/tmp -DWITH_SSL=system | tee /tmp/5.7_opt_build
make | tee -a /tmp/5.7_opt_build
./scripts/make_binary_distribution | tee -a /tmp/5.7_opt_build
TAR_opt=`ls -1 *.tar.gz | head -n1`
TAR_opt_new=$(echo "${1}-${TAR_opt}" | sed 's|.tar.gz|-opt.tar.gz|')
mv ${TAR_opt} ../${TAR_opt_new}
cd ..
tar -xf ${TAR_opt_new}
DIR_opt=$(echo "${TAR_opt}" | sed 's|.tar.gz||')
DIR_opt_new=$(echo "${TAR_opt_new}" | sed 's|.tar.gz||')
mv ${DIR_opt} ${DIR_opt_new}
echo "Done! Now run;"
echo "mv ../${DIR_opt_new} /sda"  # The script will end still in $PWD, hence we will need ../ (output only)
rm -Rf ${CURPATH}_opt
