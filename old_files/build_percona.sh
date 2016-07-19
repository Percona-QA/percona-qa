#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

echo 'THIS SCRIPT IS OUTDATED. TO GET THE NIGHTLY PERCONA QA BUILDS, USE get_percona.sh INSTEAD'
echo 'IF YOU STILL WOULD LIKE TO CONTINUE (FOR EXAMPLE BUILDING PERCONA SERVER FOR FEATURE TESTING), HIT ENTER TWICE'
read -p "Hit enter or CTRL-C now:"
read -p "Hit enter or CTRL-C now:"

# The first option is the bzr tree name on lp. If it is not passed, check if the local tree = a source tree ready for building
if [ -z $1 ]; then
  if [ ! -r Makefile -a ! -r Makefile-ps -a ! -r CMakeLists.txt ]; then 
    echo "No bzr tree name (for example "lp:percona-server/5.6" was specified (as first option to this script to enable pull and build mode),"
    echo "and the current directory is not a source tree (to enable build mode only). Exiting"
    exit 1
  fi
else
  bzr branch $1
  DIR=$(echo "$1" | sed 's|.*/||')
  cd $DIR
  if [ ! -r Makefile -a ! -r Makefile-ps -a ! -r CMakeLists.txt ]; then 
    echo "Something went wrong. Branch was pulled but there is no 'Makefile', 'Makefile-ps' or 'CMakeLists.txt' in the current directory $PWD. Exiting"
    exit 1
  fi
fi

# Setup gmock (avoids certain compilation issues) 
if [ -r '/bzr/gmock-1.6.0.zip' ]; then
  export WITH_GMOCK=/bzr/gmock-1.6.0.zip
else
  echo "Assert: This script expects gmock-1.6.0.zip in /bzr! Aborting."
  echo "cd /bzr; wget https://googlemock.googlecode.com/files/gmock-1.6.0.zip"
  exit 1
fi

CURDIR=$PWD  # The source code directory containing at least Makefile file
cd ${CURDIR}/..
rm -Rf ${CURDIR}_opt ${CURDIR}_dbg ${CURDIR}_val
cp -R ${CURDIR} ${CURDIR}_opt
cp -R ${CURDIR} ${CURDIR}_dbg
cp -R ${CURDIR} ${CURDIR}_val

cd ${CURDIR}_opt
if [ -d ./build-ps ]; then
  ./build-ps/build-binary.sh . > /tmp/percona_opt 2>&1 &
   PID_opt=$!
  cd ${CURDIR}_dbg
  ./build-ps/build-binary.sh --debug . > /tmp/percona_dbg 2>&1 &
   PID_dbg=$!
  cd ${CURDIR}_val
  ./build-ps/build-binary.sh --debug --valgrind . > /tmp/percona_val 2>&1 &
   PID_val=$!
elif [ -d ./build ]; then
  ./build/build-binary.sh . > /tmp/percona_opt 2>&1 &
   PID_opt=$!
  cd ${CURDIR}_dbg
  ./build/build-binary.sh --debug . > /tmp/percona_dbg 2>&1 &
   PID_dbg=$!
  cd ${CURDIR}_val
  ./build/build-binary.sh --debug --valgrind . > /tmp/percona_val 2>&1 &
   PID_val=$!
else
  echo "Something went wrong. There is no 'build-ps' or 'build' directory in the current directory $PWD. Exiting"
  exit 1
fi
wait $PID_opt $PID_dbg $PID_val

# Make sure builds are done / disks are in sync
sync
sleep 1

cd ${CURDIR}_opt
TAR_opt=`ls -1 *.tar.gz | head -n1`
mv $TAR_opt ${CURDIR}/..
cd ${CURDIR}_dbg
TAR_dbg=`ls -1 *.tar.gz | head -n1`
mv $TAR_dbg ${CURDIR}/..
cd ${CURDIR}_val
TAR_val=`ls -1 *.tar.gz | head -n1`
mv $TAR_val ${CURDIR}/..

cd ${CURDIR}/..
rm -Rf ${CURDIR}_opt ${CURDIR}_dbg ${CURDIR}_val

tar -xf $TAR_opt > /dev/null &
 PID_opt=$!
tar -xf $TAR_dbg > /dev/null &
 PID_dbg=$!
tar -xf $TAR_val > /dev/null &
 PID_val=$!
wait $PID_opt $PID_dbg $PID_val

echo "Done! There are now 3 builds ready as follows:"
DIR_opt=$(echo "$TAR_opt" | sed 's|.tar.gz||')
DIR_dbg=$(echo "$TAR_dbg" | sed 's|.tar.gz||')
DIR_val=$(echo "$TAR_val" | sed 's|.tar.gz||')
echo -e "${DIR_opt}\n  | Extracted from ${TAR_opt}\n  | Compile log in /tmp/percona_opt"
echo -e "${DIR_dbg}\n  | Extracted from ${TAR_dbg}\n  | Compile log in /tmp/percona_dbg"
echo -e "${DIR_val}\n  | Extracted from ${TAR_val}\n  | Compile log in /tmp/percona_val"
echo -e "Copy commands for your convenience:\ncd ..\nmv ${DIR_opt}\t\t\t /ssd\n  mv ${DIR_dbg}\t\t\t /ssd\n  mv ${DIR_val}\t /ssd"
