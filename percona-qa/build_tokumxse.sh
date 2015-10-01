#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

WORK_DIR=/tmp/tokumxse_debug_build   # Default: /tmp/tokumxse_debug_build
MXSE_BRANCH=tokumxse-1.0.0-rc.6      # For example, tokumxse-1.0.0-rc.6
BUILD_TYPE=2                         # 1: Release build | 2: Debug build | 3: Valrind build (includes Debug)

echoit(){ echo "  [$(date +'%T')] $1"; }
echoitn(){ echo -n "  [$(date +'%T')] $1"; }
echoitf(){ echo " $1"; }

#SCRIPT_PWD=$(cd `dirname $0` && pwd)
THREADS=$(grep -c processor /proc/cpuinfo)

echoitn "Checking prerequisites..."
# ==========================================================
if ! which git 1>/dev/null 2>&1; then
  echoitf "Failed!"
  echoit "Assert: git ($ sudo yum install git) required, but not present. Exiting"
  exit 1
fi

if ! which scons 1>/dev/null 2>&1; then
  echoitf "Failed!"
  echoit "Assert: scons ($ sudo yum install scons) required, but not present. Exiting"
  exit 1
fi

if ! which cmake 1>/dev/null 2>&1; then
  echoitf "Failed!"
  echoit "Assert: cmake ($ sudo yum install cmake) required (version 2.8.10 or higher), but not present. Exiting"
  exit 1
else
  CMAKE_VERSION=$(cmake --version 2>/dev/null | grep -o "[2-9]\.[8-9]\.[1-9][0-9]")  # The [8-9]\.[1-9] needs to become [0-9]\.[0-9] on a major release
  if [ "${CMAKE_VERSION}" == "" ]; then
    echoitf "Failed!"
    echoit "Assert: cmake 2.8.10 or higher required, but detected version is ${CMAKE_VERSION}. Exiting"
    exit 1
  fi
fi

if ! which gcc 1>/dev/null 2>&1; then
  echoitf "Failed!"
  echoit "Assert: gcc ($ sudo yum install gcc) required (version 4.7 or higher), but not present. Exiting"
  exit 1
else
  GCC_VERSION=$(gcc --version | grep -o "[4-9]\.[8-9]\.[2-9]" | head -n1)
  if [ "${GCC_VERSION}" == "" ]; then
    echoitf "Failed!"
    echoit "Assert: gcc 4.7 or higher required, but detected version is ${GCC_VERSION}. Exiting"
    exit 1
  fi
fi

if ! which g++ 1>/dev/null 2>&1; then
  echoitf "Failed!"
  echoit "Assert: g++ ($ sudo yum install gcc) required (version 4.7 or higher), but not present. Exiting"
  exit 1
else
  GPP_VERSION=$(g++ --version | grep -o "[4-9]\.[8-9]\.[2-9]" | head -n1)
  if [ "${GPP_VERSION}" == "" ]; then
    echoitf "Failed!"
    echoit "Assert: g++ 4.7 or higher required, but detected version is ${GPP_VERSION}. Exiting"
    exit 1
  fi
fi

if [ "$(yum list installed | grep -o "zlib-devel" | head -n1)" != "zlib-devel" ]; then
  echoitf "Failed!"
  echoit "Assert: zlib-devel ($ sudo yum install zlib-devel) required, but not present. Exiting"
  exit 1
fi
echoitf "Done!"  # Prerequisites done

echoitn "[Re-]creating temporary working directories..."
# ==========================================================
rm -Rf ${WORK_DIR}
mkdir ${WORK_DIR} ${WORK_DIR}/install
cd ${WORK_DIR}

if [ ! -d ${WORK_DIR} ]; then
  echoitf "Failed!"
  echoit "Assert: failed to create ${WORK_DIR}! Disk fulll or privileges incorrect? Exiting."
  exit 1
fi
echoitf "Done! /tmp/tokumxse_debug_build"

echoit "Cloning git project ft-index into working directory..."
# ==========================================================
git clone https://github.com/Tokutek/ft-index.git
echoitf "Tree: ft-index - Done!"

echoit "Cloning git project jemalloc into working directory..."
# ==========================================================
git clone https://github.com/Tokutek/jemalloc.git
echoitf "Tree: jemalloc Done!"

echoit "Cloning git project tokumxse into working directory..."
# ==========================================================
git clone https://github.com/Tokutek/tokumxse.git
echoitf "Tree: tokumxse Done!"

echoit "Selecting TokuMXSE branch ${MXSE_BRANCH} as per settings..."
cd ${WORK_DIR}/tokumxse
git checkout ${MXSE_BRANCH}
cd ${WORK_DIR}/ft-index
git checkout ${MXSE_BRANCH}
cd ${WORK_DIR}/jemalloc
git checkout ${MXSE_BRANCH}
echoitf "Branch selecting: Done!"

echoit "Creating symlink for jemalloc inside ft-index tree..."
cd ${WORK_DIR}/ft-index
ln -s ${PWD}/../jemalloc third_party/
echoitf "Symlink: jemalloc: Done!"

#echoit "-Werror hack"  # Disables warnings being treated as errors in all packages. May be handy for when there are code issues
#sed -i "s|-Werror||" ${WORK_DIR}/jemalloc/configure
#sed -i "s|-Werror||" ${WORK_DIR}/jemalloc/configure.ac
#sed -i "s|-Werror||" ${WORK_DIR}/ft-index/cmake_modules/TokuSetupCompiler.cmake
#sed -i "s|-Werror||" ${WORK_DIR}/tokumxse/SConstruct
#echoitif "-Werror hack: Done!"

echoit "Compiling ft-index..."
mkdir ${WORK_DIR}/ft-index/build
cd ${WORK_DIR}/ft-index/build
if [ ${BUILD_TYPE} -eq 1 ]; then
  CMAKE="-D CMAKE_BUILD_TYPE=Release -D USE_VALGRIND=OFF -D TOKU_DEBUG_PARANOID=OFF -D BUILD_TESTING=OFF"
elif [ ${BUILD_TYPE} -eq 2 ]; then
  CMAKE="-D CMAKE_BUILD_TYPE=Debug -D TOKU_DEBUG_PARANOID=ON -D BUILD_TESTING=OFF"
elif [ ${BUILD_TYPE} -eq 3 ]; then
  CMAKE="-D CMAKE_BUILD_TYPE=Debug -D USE_VALGRIND=ON -D TOKU_DEBUG_PARANOID=ON -D BUILD_TESTING=OFF"
fi
cmake ${CMAKE} -D CMAKE_INSTALL_PREFIX=${WORK_DIR}/install ..
make -j${THREADS} install
echoitf "ft-index: Compile: Done!"

echoit "Creating symlink for Fractal Tree"
cd ${WORK_DIR}/tokumxse
ln -s ${WORK_DIR}/install src/third_party/tokuft
echoitf "Symlink: Fractar Tree: Done!"

echoit "Building TokuMXSE with SCons"
cd ${WORK_DIR}/tokumxse
if [ ${BUILD_TYPE} -eq 1 ]; then
  scons --opt=on -j${THREADS} CPPPATH=./src/third_party/tokuft/include LIBPATH=$PWD/src/third_party/tokuft/lib --tokuft --allocator=jemalloc mongod mongos mongo
elif [ ${BUILD_TYPE} -eq 2 ]; then
  scons --dbg=on -j${THREADS} CPPPATH=./src/third_party/tokuft/include LIBPATH=$PWD/src/third_party/tokuft/lib --tokuft --allocator=jemalloc mongod mongos mongo
elif [ ${BUILD_TYPE} -eq 3 ]; then
  scons --dbg=on -j${THREADS} CPPPATH=./src/third_party/tokuft/include LIBPATH=$PWD/src/third_party/tokuft/lib --tokuft --allocator=jemalloc mongod mongos mongo
fi
echoitf "TokuMXSE SCons build: Done!"

echoit "Build process complete! Your build is available in ${WORK_DIR}"
