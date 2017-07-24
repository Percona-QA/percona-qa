#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script may need a few improvements, alike to build_5.x_dbg.sh 

# The first option is the bzr tree name on lp. If it is not passed, check if the local tree = a source tree ready for building
if [ -z $1 ]; then
  if [ ! -r CMakeLists.txt ]; then 
    echo "No bzr tree name (for example "lp:percona-xtrabackup/2.2" was specified (as first option to this script to enable pull and build mode),"
    echo "and the current directory is not a source tree (to enable build mode only). Exiting"
    exit 1
  fi
else
  bzr branch $1
  DIR=$(echo "$1" | sed 's|.*/||')
  cd $DIR
  if [ ! -r CMakeLists.txt ]; then 
    echo "Something went wrong. Branch was pulled but there is no "Makefile" in the current directory $PWD. Exiting"
    exit 1
  fi
fi

# Setup gmock (avoids certain compilation issues) 
if [ -r '/bzr/gmock-1.6.0.zip' ]; then
  export WITH_GMOCK=/bzr/gmock-1.6.0.zip
fi

TIMEF=`date +%d%m%y-%H%M`

generate_tarball(){
  BUILD_TYPE=$(echo ${PWD} | sed 's/.*_//')
  NAME=xtrabackup-${BUILD_TYPE}-${TIMEF}
  TARGET=./${NAME}
  mkdir -p ${TARGET}/bin ${TARGET}/share/percona-xtrabackup-test
  install -m 755 ./storage/innobase/xtrabackup/src/xtrabackup ${TARGET}/bin
  install -m 755 ./storage/innobase/xtrabackup/src/xbstream ${TARGET}/bin
  install -m 755 ./storage/innobase/xtrabackup/src/xbcrypt ${TARGET}/bin
  install -m 755 ./storage/innobase/xtrabackup/innobackupex ${TARGET}/bin
  cp -R ${PWD}/storage/innobase/xtrabackup/test ${TARGET}/share/percona-xtrabackup-test
  tar -zhcf "${NAME}.tar.gz" --owner=0 --group=0 ${NAME}/*
  mv ${TARGET} ${CURDIR}/..
  mv ${NAME}.tar.gz ${CURDIR}/..
}

CURDIR=$PWD  # The source code directory containing at least the CMakeLists.txt file
cd ${CURDIR}/..
rm -Rf ${CURDIR}_opt ${CURDIR}_dbg ${CURDIR}_val
cp -R ${CURDIR} ${CURDIR}_opt
cp -R ${CURDIR} ${CURDIR}_dbg
cp -R ${CURDIR} ${CURDIR}_val

cd ${CURDIR}_opt
  cmake -DBUILD_CONFIG=xtrabackup_release > /tmp/xtrabackup_opt 2>&1 \
  && make -j4 >> /tmp/xtrabackup_opt 2>&1 &
  PID_opt=$!
cd ${CURDIR}_dbg
  cmake -DWITH_DEBUG=ON > /tmp/xtrabackup_dbg 2>&1 \
  && make -j4 >> /tmp/xtrabackup_dbg 2>&1 &
  PID_dbg=$!
cd ${CURDIR}_val
  cmake -DWITH_DEBUG=ON -DWITH_VALGRIND=1 > /tmp/xtrabackup_val 2>&1 \
  && make -j4 >> /tmp/xtrabackup_val 2>&1 &
  PID_val=$!
wait $PID_opt $PID_dbg $PID_val

# Make sure builds are done / disks are in sync
sync
sleep 1

cd ${CURDIR}_opt; generate_tarball
cd ${CURDIR}_dbg; generate_tarball
cd ${CURDIR}_val; generate_tarball
cd ${CURDIR}/..

TAR_opt=`ls -1 xtrabackup-opt-${TIMEF}.tar.gz | head -n1`
TAR_dbg=`ls -1 xtrabackup-dbg-${TIMEF}.tar.gz | head -n1`
TAR_val=`ls -1 xtrabackup-val-${TIMEF}.tar.gz | head -n1`

echo "Done! There are now 3 builds ready as follows:"
echo -e "xtrabackup-opt-${TIMEF}\n  | Tarball: ${TAR_opt}\n  | Compile log in /tmp/xtrabackup_opt"
echo -e "xtrabackup-dbg-${TIMEF}\n  | Tarball: ${TAR_dbg}\n  | Compile log in /tmp/xtrabackup_dbg"
echo -e "xtrabackup-val-${TIMEF}\n  | Tarball: ${TAR_val}\n  | Compile log in /tmp/xtrabackup_val"
echo -e "Copy commands for your convenience:\n  mv xtrabackup-opt-${TIMEF}\t\t\t /ssd\n  mv xtrabackup-dbg-${TIMEF}\t\t\t /ssd\n  mv xtrabackup-val-${TIMEF}\t\t\t /ssd"
