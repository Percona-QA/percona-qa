#!/bin/bash

WORK_DIR=/tmp/tokumx_debug_build   # Default: /tmp/tokumx_debug_build
MX_BRANCH=tokumx-2.4.0             # For example, tokumx-1.0.0-rc.5
BUILD_TYPE=2                       # 1: Release build | 2: Debug build | 3: Valrind build (includes Debug)

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

#if ! which scons 1>/dev/null 2>&1; then
#  echoitf "Failed!"
#  echoit "Assert: scons ($ sudo yum install scons) required, but not present. Exiting"
#  exit 1
#fi

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
echoitf "Done! /tmp/tokumx_debug_build"

echoit "Cloning git project mongo working directory..."
# ==========================================================
git clone https://github.com/Tokutek/mongo
echoitf "Tree: mongo - Done!"

echoit "Cloning git project ft-index into working directory..."
# ==========================================================
git clone https://github.com/Tokutek/ft-index
echoitf "Tree: ft-index - Done!"

echoit "Cloning git project jemalloc into working directory..."
# ==========================================================
git clone https://github.com/Tokutek/jemalloc
echoitf "Tree: jemalloc Done!"

echoit "Cloning git project backup-community into working directory..."
# ==========================================================
git clone https://github.com/Tokutek/backup-community
echoitf "Tree: backup-community Done!"

echoit "Selecting TokuMX branch ${MX_BRANCH} as per settings..."
cd ${WORK_DIR}/mongo
git checkout ${MX_BRANCH}
cd ${WORK_DIR}/ft-index
git checkout ${MX_BRANCH}
cd ${WORK_DIR}/jemalloc
git checkout ${MXSE_BRANCH}
cd ${WORK_DIR}/backup-community
git checkout ${MXSE_BRANCH}
echoitf "Branch selecting: Done!"

echoit "Creating symlinks in src/third_party"
cd ${WORK_DIR}
ln -snf ${WORK_DIR}/jemalloc ft-index/third_party/jemalloc
cd mongo
ln -snf ${WORK_DIR}/ft-index src/third_party/ft-index
ln -snf ${WORK_DIR}/backup-community/backup src/third_party/backup

echoit "Creating build directory.."
mkdir build
cd build

if [ ${BUILD_TYPE} -eq 1 ]; then
  CMAKE="-D CMAKE_BUILD_TYPE=Release -D TOKU_DEBUG_PARANOID=OFF -D USE_VALGRIND=OFF -D USE_BDB=OFF -D BUILD_TESTING=OFF -D TOKUMX_DISTNAME=1.4.0"
elif [ ${BUILD_TYPE} -eq 2 ]; then
  CMAKE="-D CMAKE_BUILD_TYPE=Debug -D TOKU_DEBUG_PARANOID=ON -D USE_VALGRIND=OFF -D USE_BDB=OFF -D BUILD_TESTING=OFF -D TOKUMX_DISTNAME=1.4.0"
elif [ ${BUILD_TYPE} -eq 3 ]; then
  CMAKE="-D CMAKE_BUILD_TYPE=Debug -D TOKU_DEBUG_PARANOID=ON -D USE_VALGRIND=ON -D USE_BDB=OFF -D BUILD_TESTING=OFF -D TOKUMX_DISTNAME=1.4.0"
fi
cmake ${CMAKE} -D CMAKE_INSTALL_PREFIX=${WORK_DIR}/install ..
echoitf "TokuMX: Compile: Done!"

echoitf "TokuMX: building the tarballs.."
echo ${THREADS}
make -j${THREADS} package

echoit "Build process complete! Your build is available in ${PWD}"

