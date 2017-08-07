#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

#####
## THIS SCRIPT IS OUTDATED! Instead, build_5.x_opt.sh needs to be updated with RocksDB build functionality, in a similar fashion as 
##                          build_5.x_debug.sh works (which supports both normal as well as RocksDB build functionality). Then this
##                          script (build_5.x_opt_rocks.sh) can be deleted.
#####

MAKE_THREADS=1

if [ ! -r VERSION ]; then
  echo "Assert: 'VERSION' file not found!"
fi

ASAN=
if [ "${1}" != "" ]; then
  echo "Building with ASAN enabled"
  ASAN="-DWITH_ASAN=ON"
fi

DATE=$(date +'%d%m%y')
PREFIX=
MS=0

if [ "$(grep "MYSQL_VERSION_EXTRA=" VERSION | sed 's|MYSQL_VERSION_EXTRA=||;s|[ \t]||g')" == "" ]; then  # MS has no extra version number
  MS=1
  PREFIX="ROCKS-MS${DATE}"
else
  PREFIX="ROCKS-PS${DATE}"
fi

CURPATH=$(echo $PWD | sed 's|.*/||')

cd ..
rm -Rf ${CURPATH}_opt
rm -f /tmp/5.7_opt_build
cp -R ${CURPATH} ${CURPATH}_opt
cd ${CURPATH}_opt

### TEMPORARY HACK TO AVOID COMPILING TB (WHICH IS NOT READY YET)
rm -Rf ./plugin/tokudb-backup-plugin

cmake . -DWITH_ZLIB=system -DBUILD_CONFIG=mysql_release -DFEATURE_SET=community -DWITH_EMBEDDED_SERVER=OFF -DENABLE_DOWNLOADS=1 -DDOWNLOAD_BOOST=1 -DWITH_BOOST=/tmp -DWITH_SSL=system -DWITH_PAM=ON -DWITH_ROCKSDB=1 ${ASAN} | tee /tmp/5.7_opt_build
if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
if [ "${ASAN}" != "" -a $MS -eq 1 ]; then
  ASAN_OPTIONS="detect_leaks=0" make -j${MAKE_THREADS} | tee -a /tmp/5.7_opt_build  # Upstream is affected by http://bugs.mysql.com/bug.php?id=80014 (fixed in PS)
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
else
  make -j${MAKE_THREADS} | tee -a /tmp/5.7_opt_build
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
fi
./scripts/make_binary_distribution | tee -a /tmp/5.7_opt_build  # Note that make_binary_distribution is created on-the-fly during the make compile
if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
TAR_opt=`ls -1 *.tar.gz | head -n1`
if [[ "${TAR_opt}" == *".tar.gz"* ]]; then
  DIR_opt=$(echo "${TAR_opt}" | sed 's|.tar.gz||')
  TAR_opt_new=$(echo "${PREFIX}-${TAR_opt}" | sed 's|.tar.gz|-opt.tar.gz|')
  DIR_opt_new=$(echo "${TAR_opt_new}" | sed 's|.tar.gz||')
  if [ "${DIR_opt}" != "" ]; then rm -Rf ../${DIR_opt}; fi
  if [ "${DIR_opt_new}" != "" ]; then rm -Rf ../${DIR_opt_new}; fi
  if [ "${TAR_opt_new}" != "" ]; then rm -Rf ../${TAR_opt_new}; fi
  mv ${TAR_opt} ../${TAR_opt_new}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
  cd ..
  tar -xf ${TAR_opt_new}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
  mv ${DIR_opt} ${DIR_opt_new}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
  echo "Done! Now run;"
  echo "mv ../${DIR_opt_new} /sda"  # The script will end still in $PWD, hence we will need ../ (output only)
  #rm -Rf ${CURPATH}_opt  # Best not to delete it; this way gdb debugging is better quality as source will be available!
  exit 0
else
  echo "There was some build issue... Have a nice day!"
  exit 1
fi
