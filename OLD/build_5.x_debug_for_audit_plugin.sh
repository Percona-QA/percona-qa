#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

MAKE_THREADS=8          # Number of build threads. There may be a bug with >1 settings
WITH_ROCKSDB=1          # 0 or 1 # Please note when building the facebook-mysql-5.6 tree this setting is automatically ignored
                                 # For daily builds of fb tree (opt and debug) also see http://jenkins.percona.com/job/fb-mysql-5.6/
                                 # This is also auto-turned off for all 5.5 and 5.6 builds
WITH_EMBEDDED_SERVER=0  # 0 or 1 # Include the embedder server (removed in 8.0)
WITH_LOCAL_INFILE=0     # 0 or 1 # Include the possibility to use LOAD DATA LOCAL INFILE (LOCAL option was removed in 8.0?)
ZLIB_MYSQL8_HACK=1      # 0 or 1 # Use -DWITH_ZLIB=bundled instead of =system for bug https://bugs.mysql.com/bug.php?id=89373
USE_BOOST_LOCATION=0    # 0 or 1 # Use a custom boost location to avoid boost re-download
BOOST_LOCATION=/git/boost_1_59_0-debug/
USE_CUSTOM_COMPILER=0   # 0 or 1 # Use a customer compiler
CUSTOM_COMPILER_LOCATION="/home/roel/GCC-5.5.0/bin"
USE_CLANG=0             # 0 or 1 # Use the clang compiler instead of gcc
CLANG_LOCATION="/home/roel/third_party/llvm-build/Release+Asserts/bin/clang"  # Should end in /clang (and assumes presence of /clang++)
USE_AFL=0               # 0 or 1 # Use the American Fuzzy Lop gcc/g++ wrapper instead of gcc/g++
AFL_LOCATION="$(cd `dirname $0` && pwd)/fuzzer/afl-2.52b"

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
  exit 1
fi

if [ $USE_CLANG -eq 1 -a $USE_AFL -eq 1 ]; then
  echo "Assert: USE_CLANG and USE_AFL are both set to 1 but they are mutually exclusive. Please set one (or both) to 0."
  exit 1
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
FB=0
MS=0
if [ ! -d rocksdb ]; then  # MS, PS
  VERSION_EXTRA="$(grep "MYSQL_VERSION_EXTRA=" VERSION | sed 's|MYSQL_VERSION_EXTRA=||;s|[ \t]||g')"
  if [ "${VERSION_EXTRA}" == "" -o "${VERSION_EXTRA}" == "-dmr" -o "${VERSION_EXTRA}" == "-rc" ]; then  # MS has no extra version number, or shows '-dmr' or '-rc' (both exactly and only) in this place
    MS=1
    PREFIX="MS${DATE}"
  else
    PREFIX="PS${DATE}"
  fi
else
  PREFIX="FB${DATE}"
  FB=1
fi

# MySQL8 zlib Hack
ZLIB="-DWITH_ZLIB=system"
if [ $ZLIB_MYSQL8_HACK -eq 1 ]; then
  ZLIB="-DWITH_ZLIB=bundled"
fi

# Use CLANG compiler
CLANG=
if [ $USE_CLANG -eq 1 ]; then
  if [ $USE_CUSTOM_COMPILER -eq 1 ]; then
    echo "Both USE_CLANG and USE_CUSTOM_COMPILER are enabled, while they are mutually exclusive; this script can only one custom compiler! Terminating."
    exit 1
  fi
  echo "======================================================"
  echo "Note: USE_CLANG is set to 1, using the clang compiler!"
  echo "======================================================"
  sleep 3
  CLANG="-DCMAKE_C_COMPILER=$CLANG_LOCATION -DCMAKE_CXX_COMPILER=${CLANG_LOCATION}++"  # clang++ location is assumed to be same with ++
fi

# Use AFL gcc/g++ wrapper as compiler
AFL=
if [ $USE_AFL -eq 1 ]; then
  if [ $USE_CLANG -eq 1 ]; then
    echo "Both USE_CLANG and USE_AFL are enabled, while they are mutually exclusive; this script can only one custom compiler! Terminating."
    exit 1
  fi
  if [ $USE_CUSTOM_COMPILER -eq 1 ]; then
    echo "Both USE_AFL and USE_CUSTOM_COMPILER are enabled, while they are mutually exclusive; this script can only one custom compiler! Terminating."
    exit 1
  fi
  echo "====================================================================="
  echo "Note: USE_AFL is set to 1, using the AFL gcc/g++ wrapper as compiler!"
  echo "====================================================================="
  echo "Note: ftm, AFL builds exclude RocksDB"
  echo "====================================================================="
  echo "Note: ftm, AFL builds require patching source code, ask Roel how to"
  echo "====================================================================="
  sleep 3
  WITH_ROCKSDB=0
  #AFL="-DWITH_TOKUDB=0 -DCMAKE_C_COMPILER=$AFL_LOCATION/afl-gcc -DCMAKE_CXX_COMPILER=$AFL_LOCATION/afl-g++"
  AFL="-DCMAKE_C_COMPILER=$AFL_LOCATION/afl-gcc -DCMAKE_CXX_COMPILER=$AFL_LOCATION/afl-g++"
fi

# Use a custom compiler
CUSTOM_COMPILER=
if [ $USE_CUSTOM_COMPILER -eq 1 ]; then
  CUSTOM_COMPILER="-DCMAKE_C_COMPILER=${CUSTOM_COMPILER_LOCATION}/gcc -DCMAKE_CXX_COMPILER=${CUSTOM_COMPILER_LOCATION}/g++"
fi

FLAGS=
# Attemting to use something like    -CMAKE_C_FLAGS_DEBUG="-Wno-error" -CMAKE_CXX_FLAGS_DEBUG="-Wno-error -march=native"    Does not work here
# Using -Wno-error does not work either because of BLD-930
# In the end, using -w (produce no warnings at all when AFL is used as warnings are treated as errors and this prevents afl-gcc/afl-g++ from completing)
if [ $USE_AFL -eq 1 ]; then
  if [ $FB -eq 1 ]; then
    # The next line misses the -w but have not figured out a way to make the '-w' work in combination with '-march=native'
    # Single quotes may work
    FLAGS='-DCMAKE_CXX_FLAGS=-march=native'  # -DCMAKE_CXX_FLAGS="-march=native" is the default for FB tree
  else
    FLAGS="-DCMAKE_CXX_FLAGS=-w"
  fi
else
  if [ $FB -eq 1 ]; then
    FLAGS='-DCMAKE_CXX_FLAGS=-march=native'  # -DCMAKE_CXX_FLAGS="-march=native" is the default for FB tree
  fi
fi
# Also note that -k can be use for make to ignore any errors; if the build fails somewhere in the tests/unit tests then it matters
# little. Note that -k is not a compiler flag as -w is. It is a make option.

CURPATH=$(echo $PWD | sed 's|.*/||')

cd ..
rm -Rf ${CURPATH}_dbg
rm -f /tmp/5.x_debug_build_${RANDOMD}
cp -R ${CURPATH} ${CURPATH}_dbg
cd ${CURPATH}_dbg

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
  cmake . $CLANG $AFL -DCMAKE_BUILD_TYPE=Debug -DWITH_SSL=system -DBUILD_CONFIG=mysql_release -DFEATURE_SET=community -DDEBUG_EXTNAME=OFF -DWITH_EMBEDDED_SERVER=${WITH_EMBEDDED_SERVER} -DENABLE_DOWNLOADS=1 ${BOOST} -DENABLED_LOCAL_INFILE=${WITH_LOCAL_INFILE} -DENABLE_DTRACE=0 -DWITH_PERFSCHEMA_STORAGE_ENGINE=1 ${ZLIB} -DWITH_ROCKSDB=${WITH_ROCKSDB} -DWITH_PAM=ON ${ASAN} ${FLAGS} | tee /tmp/5.x_debug_build_${RANDOMD}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected for make!"; exit 1; fi
else
  # FB build
  cmake . $CLANG $AFL -DCMAKE_BUILD_TYPE=Debug -DWITH_SSL=system -DBUILD_CONFIG=mysql_release -DFEATURE_SET=community -DDEBUG_EXTNAME=OFF -DWITH_EMBEDDED_SERVER=${WITH_EMBEDDED_SERVER} -DENABLE_DOWNLOADS=1 ${BOOST} -DENABLED_LOCAL_INFILE=${WITH_LOCAL_INFILE} -DENABLE_DTRACE=0 -DWITH_PERFSCHEMA_STORAGE_ENGINE=1 ${ZLIB} -DMYSQL_MAINTAINER_MODE=0 ${FLAGS} | tee /tmp/5.x_debug_build_${RANDOMD}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected for make!"; exit 1; fi
fi
if [ "${ASAN}" != "" -a $MS -eq 1 ]; then
  ASAN_OPTIONS="detect_leaks=0" make -j${MAKE_THREADS} | tee -a /tmp/5.x_debug_build_${RANDOMD}  # Upstream is affected by http://bugs.mysql.com/bug.php?id=80014 (fixed in PS)
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected for make!"; exit 1; fi
else
  make -j${MAKE_THREADS} | tee -a /tmp/5.x_debug_build_${RANDOMD}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected for make!"; exit 1; fi
fi

if [ ! -r ./scripts/make_binary_distribution ]; then  # Note: ./scripts/binary_distribution is created on-the-fly during the make compile
  echo "Assert: ./scripts/make_binary_distribution was not found. Terminating."
  exit 1
else
  ./scripts/make_binary_distribution | tee -a /tmp/5.x_debug_build_${RANDOMD}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected for ./scripts/make_binary_distribution!"; exit 1; fi
fi

TAR_dbg=`ls -1 *.tar.gz | grep -v "boost" | head -n1`
if [[ "${TAR_dbg}" == *".tar.gz"* ]]; then
  DIR_dbg=$(echo "${TAR_dbg}" | sed 's|.tar.gz||')
  TAR_dbg_new=$(echo "${PREFIX}-${TAR_dbg}" | sed 's|.tar.gz|-debug.tar.gz|')
  DIR_dbg_new=$(echo "${TAR_dbg_new}" | sed 's|.tar.gz||')
  if [ "${DIR_dbg}" != "" ]; then rm -Rf ../${DIR_dbg}; fi
  if [ "${DIR_dbg_new}" != "" ]; then rm -Rf ../${DIR_dbg_new}; fi
  if [ "${TAR_dbg_new}" != "" ]; then rm -Rf ../${TAR_dbg_new}; fi
  mv ${TAR_dbg} ../${TAR_dbg_new}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected for moving of tarball!"; exit 1; fi
  cd ..
  tar -xf ${TAR_dbg_new}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected for tar!"; exit 1; fi
  mv ${DIR_dbg} ${DIR_dbg_new}
  if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected for moving of tarball (2)!"; exit 1; fi
  echo "Done! Now run;"
  echo "mv ../${DIR_dbg_new} /sda"  # The script will end still in $PWD, hence we will need ../ (output only)
  #rm -Rf ${CURPATH}_dbg  # Best not to delete it; this way gdb debugging is better quality as source will be available!
  exit 0
else
  echo "There was some unknown build issue... Have a nice day!"
  exit 1
fi
