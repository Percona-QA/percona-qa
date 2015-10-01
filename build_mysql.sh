#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# The first option is the bzr tree name on lp. If it is not passed, check if the local tree = a source tree ready for building
if [ -z $1 ]; then
  if [ ! -r CMakeLists.txt ]; then 
    echo "No bzr tree name (for example "lp:mysql-server/5.6" was specified (as first option to this script to enable pull and build mode),"
    echo "and the current directory is not a source tree (to enable build mode only). Exiting"
    exit 1
  fi
else
  bzr branch $1
  DIR=$(echo "$1" | sed 's|.*/||')
  cd $DIR
  if [ ! -r CMakeLists.txt ]; then 
    echo "Something went wrong. Branch was pulled but there is no "CMakeLists.txt" in the current directory $PWD. Exiting"
    exit 1
  fi
fi

CURDIR=$PWD  # The source code directory containing at least CMakeLists.txt file
cd ${CURDIR}/..
rm -Rf ${CURDIR}_opt ${CURDIR}_dbg ${CURDIR}_val
mkdir ${CURDIR}_opt
mkdir ${CURDIR}_dbg
mkdir ${CURDIR}_val

#GENERAL_BLD_OPT="-DENABLE_DOWNLOADS=1 -DBUILD_CONFIG=mysql_release -DWITH_EMBEDDED_SERVER=OFF -DFEATURE_SET=community -DENABLE_DTRACE=OFF"
GENERAL_BLD_OPT="-DENABLE_DOWNLOADS=1 -DBUILD_CONFIG=mysql_release -DWITH_EMBEDDED_SERVER=OFF -DFEATURE_SET=community"
#In time, we need to add -DWITH_DEBUG=ON here + in build script in PS source. See mail "Debuggy" 18 Oct 2013.
#However, memcached is holding us back: https://bugs.launchpad.net/percona-server/+bug/1241455
echo $(cd ${CURDIR}_opt; \
  cmake ${GENERAL_BLD_OPT} ${CURDIR} > /tmp/mysql_opt 2>&1; \
  make >> /tmp/mysql_opt 2>&1 ; \
  ./scripts/make_binary_distribution) >> /tmp/mysql_opt 2>&1 &
 PID_opt=$!
echo $(cd ${CURDIR}_dbg; \
  cmake ${GENERAL_BLD_OPT} -DCMAKE_BUILD_TYPE=Debug -DDEBUG_EXTNAME=OFF ${CURDIR} > /tmp/mysql_dbg 2>&1; \
  make >> /tmp/mysql_dbg 2>&1 ; \
  ./scripts/make_binary_distribution) >> /tmp/mysql_dbg 2>&1 &
 PID_dbg=$!
echo $(cd ${CURDIR}_val; \
  cmake ${GENERAL_BLD_OPT} -DCMAKE_BUILD_TYPE=Debug -DDEBUG_EXTNAME=OFF -DWITH_VALGRIND=ON ${CURDIR} >/tmp/mysql_val 2>&1; \
  make >>/tmp/mysql_val 2>&1 ; \
  ./scripts/make_binary_distribution) >>/tmp/mysql_val 2>&1 &
 PID_val=$!
wait $PID_opt $PID_dbg $PID_val

# Make sure builds are done / disks are in sync
sync
sleep 1

cd ${CURDIR}_opt
TAR_opt=`ls -1 *.tar.gz | head -n1`
mv $TAR_opt ${CURDIR}/../$TAR_opt
cd ${CURDIR}_dbg
TAR_dbg=`ls -1 *.tar.gz | head -n1`
TAR_dbg_new=$(echo $TAR_dbg | sed 's|.tar.gz|-debug.tar.gz|')
mv $TAR_dbg ${CURDIR}/../$TAR_dbg_new
cd ${CURDIR}_val
TAR_val=`ls -1 *.tar.gz | head -n1`
TAR_val_new=$(echo $TAR_val | sed 's|.tar.gz|-debug-valgrind.tar.gz|')
mv $TAR_val ${CURDIR}/../$TAR_val_new

cd ${CURDIR}/..
rm -Rf ${CURDIR}_opt ${CURDIR}_dbg ${CURDIR}_val    # Remark this line for debugging

DIR_opt=$(echo $TAR_opt | sed 's|.tar.gz||')
tar -xf $TAR_val_new > /dev/null
cp ${DIR_val}/bin/mysqld-debug ${DIR_val}/bin/mysqld # Workaround for http://bugs.mysql.com/bug.php?id=69856 (MS only, or PS build in MS-way)
DIR_val=$(echo $TAR_val_new | sed 's|.tar.gz||')
mv $DIR_opt $DIR_val
tar -xf $TAR_dbg_new > /dev/null
cp ${DIR_dbg}/bin/mysqld-debug ${DIR_dbg}/bin/mysqld # Workaround for http://bugs.mysql.com/bug.php?id=69856 (MS only, or PS build in MS-way)
DIR_dbg=$(echo $TAR_dbg_new | sed 's|.tar.gz||')
mv $DIR_opt $DIR_dbg
tar -xf $TAR_opt > /dev/null

echo "Done! There are now 3 builds ready as follows:"
echo -e "${DIR_opt}\n  | Extracted from ${TAR_opt}\n  | Compile log in /tmp/mysql_opt"
echo -e "${DIR_dbg}\n  | Extracted from ${TAR_dbg_new}\n  | Compile log in /tmp/mysql_dbg"
echo -e "${DIR_val}\n  | Extracted from ${TAR_val_new}\n  | Compile log in /tmp/mysql_val"
echo -e "Copy commands for your convenience:\ncd ..\nmv ${DIR_opt}\t\t\t /ssd\n  mv ${DIR_dbg}\t\t\t /ssd\n  mv ${DIR_val}\t /ssd"
