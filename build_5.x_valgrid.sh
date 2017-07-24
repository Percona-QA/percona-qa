#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

MAKE_THREADS=1

if [ ! -r VERSION ]; then
  echo "Assert: 'VERSION' file not found!"
fi

DATE=$(date +'%d%m%y')
PREFIX=
MS=0

if [ "$(grep "MYSQL_VERSION_EXTRA=" VERSION | sed 's|MYSQL_VERSION_EXTRA=||;s|[ \t]||g')" == "" ]; then  # MS has no extra version number
  MS=1
  PREFIX="MS${DATE}"
else
  PREFIX="PS${DATE}"
fi

CURPATH=$(echo $PWD | sed 's|.*/||')

cd ..
rm -Rf ${CURPATH}_val
rm -f /tmp/5.7_valgrind_build
cp -R ${CURPATH} ${CURPATH}_val
cd ${CURPATH}_val

### TEMPORARY HACK TO AVOID COMPILING TB (WHICH IS NOT READY YET)
rm -Rf ./plugin/tokudb-backup-plugin

cmake . -DWITH_ZLIB=system -DCMAKE_BUILD_TYPE=Debug -DBUILD_CONFIG=mysql_release -DFEATURE_SET=community -DDEBUG_EXTNAME=OFF -DWITH_EMBEDDED_SERVER=OFF -DENABLE_DOWNLOADS=1 -DDOWNLOAD_BOOST=1 -DWITH_BOOST=/tmp -DWITH_SSL=system -DWITH_PAM=ON -DWITH_VALGRIND=ON | tee /tmp/5.7_valgrind_build  # Do NOT include ASAN! (ASAN crash==wrong/missed Valgrind output)
if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
make -j${MAKE_THREADS} | tee -a /tmp/5.7_valgrind_build
if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
./scripts/make_binary_distribution | tee -a /tmp/5.7_valgrind_build  # Note that make_binary_distribution is created on-the-fly during the make compile
if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
TAR_val=`ls -1 *.tar.gz | head -n1`
if [[ "${TAR_val}" == *".tar.gz"* ]]; then
  DIR_val=$(echo "${TAR_val}" | sed 's|.tar.gz||')
  TAR_val_new=$(echo "${PREFIX}-${TAR_val}" | sed 's|.tar.gz|-val.tar.gz|')
  DIR_val_new=$(echo "${TAR_val_new}" | sed 's|.tar.gz||')
  if [ "${DIR_val}" != "" ]; then rm -Rf ../${DIR_val}; fi
  if [ "${DIR_val_new}" != "" ]; then rm -Rf ../${DIR_val_new}; fi
  if [ "${TAR_val_new}" != "" ]; then rm -Rf ../${TAR_val_new}; fi
  mv ${TAR_val} ../${TAR_val_new}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
  cd ..
  tar -xf ${TAR_val_new}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
  mv ${DIR_val} ${DIR_val_new}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
  echo "Done! Now run;"
  echo "mv ../${DIR_val_new} /sda"  # The script will end still in $PWD, hence we will need ../ (output only)
  #rm -Rf ${CURPATH}_val  # Best not to delete it; this way gdb debugging is better quality as source will be available!
  exit 0
else
  echo "There was some build issue... Have a nice day!"
  exit 1
fi
