#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

SCRIPT_PWD=$(cd `dirname $0` && pwd)
if [ ! -r Makefile -a ! -r Makefile-ps -a ! -r CMakeLists.txt ]; then 
  echo "Assert: The current directory is not a source tree (to enable build mode only). Exiting"
  exit 1
fi

# Setup gmock (avoids certain compilation issues) 
if [ -r '/bzr/gmock-1.6.0.zip' ]; then
  export WITH_GMOCK=/bzr/gmock-1.6.0.zip
else
  echo "Assert: This script expects gmock-1.6.0.zip in /bzr! Aborting."
  echo "cd /bzr; wget https://googlemock.googlecode.com/files/gmock-1.6.0.zip"
  exit 1
fi

CURDIR=$PWD  # The source code directory containing at least a Makefile, Makefile-ps or CMakeLists.txt file
cd ${CURDIR}/..
rm -Rf ${CURDIR}_dbg 
cp -R ${CURDIR} ${CURDIR}_dbg
cd ${CURDIR}_dbg

if [ -d ./build-ps ]; then
  ./build-ps/build-binary.sh --debug . > /tmp/percona_dbg 2>&1 
elif [ -d ./build ]; then
  ./build/build-binary.sh --debug . > /tmp/percona_dbg 2>&1 
else
  echo "Something went wrong. There is no 'build-ps' or 'build' directory in the current directory $PWD. Exiting"
  exit 1
fi

# Make sure builds are done / disks are in sync
sync
sleep 1

TAR_dbg=`ls -1 *.tar.gz | head -n1`
mv $TAR_dbg ${CURDIR}/..

cd ${CURDIR}/..
rm -Rf ${CURDIR}_dbg 

tar -xf $TAR_dbg > /dev/null 

echo "Done! There is now a debug build ready for you as follows:"
DIR_dbg=$(echo "$TAR_dbg" | sed 's|.tar.gz||')
echo -e "${DIR_dbg}\n | Extracted from ${TAR_dbg}\n | Compile log is in /tmp/percona_dbg"
echo "Cleanup, copy and setup commands for your convenience (last one is to setup start scripts);"
echo "-------------------------------------------------------------------------------------------"
echo "cd ..; rm -Rf /sda/${DIR_dbg};"
echo "mv ${DIR_dbg} /sda; cd /sda/${DIR_dbg};"
echo "${SCRIPT_PWD}/startup.sh 0"
echo "-------------------------------------------------------------------------------------------"
