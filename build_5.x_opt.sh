#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

MAKE_THREADS=1      # Number of build threads. There may be a bug with >1 settings
WITH_ROCKSDB=1      # 0 or 1  # Please note when building the facebook-mysql-5.6 tree this setting is automatically ignored
                              # For daily builds of fb tree (opt and debug) also see http://jenkins.percona.com/job/fb-mysql-5.6/
                              # This is also auto-turned off for all 5.5 and 5.6 builds 
USE_CLANG=0         # Use the clang compiler instead of gcc
CLANG_LOCATION="/home/roel/third_party/llvm-build/Release+Asserts/bin/clang"
CLANGPP_LOCATION="${CLANG_LOCATION}++"
USE_BOOST_LOCATION=0
BOOST_LOCATION=/git/PS-5.7-trunk/boost_1_59_0.tar.gz

# To install the latest clang from Chromium devs;
# sudo yum remove clang    # Or sudo apt-get remove clang
# cd ~
# mkdir TMP_CLANG
# cd TMP_CLANG
# git clone https://chromium.googlesource.com/chromium/src/tools/clang
# cd ..
# TMP_CLANG/clang/scripts/update.py

RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')  # Random 6 digit for tmp directory name

if [ ! -r VERSION ]; then
  echo "Assert: 'VERSION' file not found!"
fi

MYSQL_VERSION_MAJOR=$(grep "MYSQL_VERSION_MAJOR" VERSION | sed 's|.*=||')
MYSQL_VERSION_MINOR=$(grep "MYSQL_VERSION_MINOR" VERSION | sed 's|.*=||')
if [ "$MYSQL_VERSION_MAJOR" == "5" ]; then
  if [ "$MYSQL_VERSION_MINOR" == "5" -o "$MYSQL_VERSION_MINOR" == "6" ]; then
    WITH_ROCKSDB=0  # This works fine for MS and PS but is not tested for MD
  fi
fi

ASAN=
if [ "${1}" != "" ]; then
  echo "Building with ASAN enabled"
  ASAN="-DWITH_ASAN=ON"
fi

DATE=$(date +'%d%m%y')
PREFIX=
MS=0
FB=0

if [ ! -d rocksdb ]; then  # MS, PS
  VERSION_EXTRA="$(grep "MYSQL_VERSION_EXTRA=" VERSION | sed 's|MYSQL_VERSION_EXTRA=||;s|[ \t]||g')"
  if [ "${VERSION_EXTRA}" == "" -o "${VERSION_EXTRA}" == "-dmr" ]; then  # MS has no extra version number, or shows '-dmr' (exactly and only) in this place
    MS=1
    PREFIX="MS${DATE}"
  else
    PREFIX="PS${DATE}"
  fi
else
  PREFIX="FB${DATE}"
  FB=1
fi

CLANG=
if [ $USE_CLANG -eq 1 ]; then
  CLANG="-DCMAKE_C_COMPILER=$CLANG_LOCATION -DCMAKE_CXX_COMPILER=$CLANGPP_LOCATION"
fi
FLAGS=
if [ $FB -eq 1 ]; then
  FLAGS='-DCMAKE_CXX_FLAGS="-march=native"'  # Default for FB tree
fi

CURPATH=$(echo $PWD | sed 's|.*/||')

cd ..
rm -Rf ${CURPATH}_opt
rm -f /tmp/5.x_opt_build_${RANDOMD}
cp -R ${CURPATH} ${CURPATH}_opt
cd ${CURPATH}_opt

### TEMPORARY HACK TO AVOID COMPILING TB (WHICH IS NOT READY YET)
rm -Rf ./plugin/tokudb-backup-plugin

BOOST=
if [ ${USE_BOOST_LOCATION} -eq 1 ]; then
  if [ ! -r ${BOOST_LOCATION} ]; then
    echo "Assert; USE_BOOST_LOCATION was set to 1, but the file at BOOST_LOCATION (${BOOST_LOCATION} cannot be read!"
    exit 1
  else
    BOOST="-DDOWNLOAD_BOOST=0 -DWITH_BOOST=${BOOST_LOCATION}"
  fi
else
  # Avoid previously downloaded boost's from creating problems
  rm -Rf /tmp/boost_${RANDOMD}
  mkdir /tmp/boost_${RANDOMD}
  BOOST="-DDOWNLOAD_BOOST=1 -DWITH_BOOST=/tmp/boost_${RANDOMD}"
fi

if [ $FB -eq 0 ]; then
  # PS,MS,PXC build
  cmake . $CLANG -DWITH_SSL=system -DBUILD_CONFIG=mysql_release -DFEATURE_SET=community -DDEBUG_EXTNAME=OFF -DWITH_EMBEDDED_SERVER=OFF -DENABLE_DOWNLOADS=1 ${BOOST} -DENABLED_LOCAL_INFILE=1 -DENABLE_DTRACE=0 -DWITH_PERFSCHEMA_STORAGE_ENGINE=1 -DWITH_ZLIB=system -DWITH_ROCKSDB=${WITH_ROCKSDB} -DWITH_PAM=ON ${ASAN} ${FLAGS} | tee /tmp/5.x_opt_build_${RANDOMD}
else
  # FB build
  cmake . $CLANG -DWITH_SSL=system -DBUILD_CONFIG=mysql_release -DFEATURE_SET=community -DDEBUG_EXTNAME=OFF -DWITH_EMBEDDED_SERVER=OFF -DENABLE_DOWNLOADS=1 ${BOOST} -DENABLED_LOCAL_INFILE=1 -DENABLE_DTRACE=0 -DWITH_PERFSCHEMA_STORAGE_ENGINE=1 -DWITH_ZLIB=bundled -DMYSQL_MAINTAINER_MODE=0 ${FLAGS} | tee /tmp/5.x_opt_build_${RANDOMD}
fi
if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
if [ "${ASAN}" != "" -a $MS -eq 1 ]; then
  ASAN_OPTIONS="detect_leaks=0" make -j${MAKE_THREADS} | tee -a /tmp/5.x_opt_build_${RANDOMD}  # Upstream is affected by http://bugs.mysql.com/bug.php?id=80014 (fixed in PS)
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
else
  make -j${MAKE_THREADS} | tee -a /tmp/5.x_opt_build_${RANDOMD}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected!"; exit 1; fi
fi

./scripts/make_binary_distribution | tee -a /tmp/5.x_opt_build_${RANDOMD}  # Note that make_binary_distribution is created on-the-fly during the make compile
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
