#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

MAKE_THREADS=1      # Number of build threads. There may be a bug with >1 settings
USE_CLANG=1         # Use the clang compiler instead of gcc
WITH_ROCKSDB=1      # 0 or 1  # Please note when building the facebook-mysql-5.6 tree this setting is automatically ignored
                              # For daily builds (optimized and debug) also see http://jenkins.percona.com/job/fb-mysql-5.6/

if [ ! -r VERSION ]; then
  echo "Assert: 'VERSION' file not found!"
fi

ASAN=
if [ "${1}" != "" ]; then
  echo "Building with ASAN enabled"
  ASAN="-DWITH_ASAN=ON"
fi

if [ $USE_CLANG -eq 1 ]; then
  CLANG="-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++"
else
  CLANG=""
fi

DATE=$(date +'%d%m%y')
PREFIX=
MS=0
FB=0

if [ -d rocksdb ]; then
  PREFIX="FB${DATE}"
  FB=1
else
  VERSION_EXTRA="$(grep "MYSQL_VERSION_EXTRA=" VERSION | sed 's|MYSQL_VERSION_EXTRA=||;s|[ \t]||g')"
  if [ "${VERSION_EXTRA}" == "" -o "${VERSION_EXTRA}" == "-dmr" ]; then  # MS has no extra version number, or shows '-dmr' (exactly and only) in this place
    MS=1
    PREFIX="MS${DATE}"
  else
    PREFIX="PS${DATE}"
  fi
fi

CURPATH=$(echo $PWD | sed 's|.*/||')

cd ..
rm -Rf ${CURPATH}_dbg
rm -f /tmp/5.7_debug_build
cp -R ${CURPATH} ${CURPATH}_dbg
cd ${CURPATH}_dbg

### TEMPORARY HACK TO AVOID COMPILING TB (WHICH IS NOT READY YET)
rm -Rf ./plugin/tokudb-backup-plugin

if [ $FB -eq 0 ]; then
  # PS,MS,PXC build
  cmake . $CLANG -DCMAKE_BUILD_TYPE=Debug -DWITH_SSL=system -DBUILD_CONFIG=mysql_release -DFEATURE_SET=community -DDEBUG_EXTNAME=OFF -DWITH_EMBEDDED_SERVER=OFF -DENABLE_DOWNLOADS=1 -DDOWNLOAD_BOOST=1 -DWITH_BOOST=/tmp -DENABLED_LOCAL_INFILE=1 -DENABLE_DTRACE=0 -DWITH_PERFSCHEMA_STORAGE_ENGINE=1 -DWITH_ZLIB=system -DWITH_ROCKSDB=${WITH_ROCKSDB} -DWITH_PAM=ON ${ASAN} | tee /tmp/5.7_debug_build
else
  # FB build
  cmake . $CLANG -DCMAKE_BUILD_TYPE=Debug -DWITH_SSL=system -DBUILD_CONFIG=mysql_release -DFEATURE_SET=community -DDEBUG_EXTNAME=OFF -DWITH_EMBEDDED_SERVER=OFF -DENABLE_DOWNLOADS=1 -DDOWNLOAD_BOOST=1 -DWITH_BOOST=/tmp -DENABLED_LOCAL_INFILE=1 -DENABLE_DTRACE=0 -DWITH_PERFSCHEMA_STORAGE_ENGINE=1 -DWITH_ZLIB=bundled -DMYSQL_MAINTAINER_MODE=0 -DCMAKE_CXX_FLAGS="-march=native" | tee /tmp/5.7_debug_build
fi
if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
if [ "${ASAN}" != "" -a $MS -eq 1 ]; then
  ASAN_OPTIONS="detect_leaks=0" make -j${MAKE_THREADS} | tee -a /tmp/5.7_debug_build  # Upstream is affected by http://bugs.mysql.com/bug.php?id=80014 (fixed in PS)
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
else
  make -j${MAKE_THREADS} | tee -a /tmp/5.7_debug_build
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
fi

./scripts/make_binary_distribution | tee -a /tmp/5.7_debug_build  # Note that make_binary_distribution is created on-the-fly during the make compile
if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
TAR_dbg=`ls -1 *.tar.gz | head -n1`
if [[ "${TAR_dbg}" == *".tar.gz"* ]]; then
  DIR_dbg=$(echo "${TAR_dbg}" | sed 's|.tar.gz||')
  TAR_dbg_new=$(echo "${PREFIX}-${TAR_dbg}" | sed 's|.tar.gz|-debug.tar.gz|')
  DIR_dbg_new=$(echo "${TAR_dbg_new}" | sed 's|.tar.gz||')
  if [ "${DIR_dbg}" != "" ]; then rm -Rf ../${DIR_dbg}; fi
  if [ "${DIR_dbg_new}" != "" ]; then rm -Rf ../${DIR_dbg_new}; fi
  if [ "${TAR_dbg_new}" != "" ]; then rm -Rf ../${TAR_dbg_new}; fi
  mv ${TAR_dbg} ../${TAR_dbg_new}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
  cd ..
  tar -xf ${TAR_dbg_new}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
  mv ${DIR_dbg} ${DIR_dbg_new}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
  echo "Done! Now run;"
  echo "mv ../${DIR_dbg_new} /sda"  # The script will end still in $PWD, hence we will need ../ (output only)
  #rm -Rf ${CURPATH}_dbg  # Best not to delete it; this way gdb debugging is better quality as source will be available!
  exit 0
else
  echo "There was some build issue... Have a nice day!"
  exit 1
fi
