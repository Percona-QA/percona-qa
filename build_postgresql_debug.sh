#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC

CURPATH=$PWD

cd ..
rm -Rf ${CURPATH}_dbg
cp -R ${CURPATH} ${CURPATH}_dbg
cd ${CURPATH}_dbg
DATE=$(date +'%d%m%y')
PREFIX="${CURPATH}_dbg/build"

${CURPATH}_dbg/configure --enable-debug --prefix=$PREFIX | tee ${CURPATH}_dbg/debug_build_configure.log
if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected for ./configure!"; exit 1; fi
gmake | tee ${CURPATH}_dbg/debug_build_gmake.log
if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected for gmake!"; exit 1; fi
gmake install | tee ${CURPATH}_dbg/debug_build_gmake_install.log
if [ $? -ne 0 ]; then echo "Assert: non-0 exit status detected for gmake install!"; exit 1; fi

VERSION=`$PREFIX/bin/postgres --version | awk '{print $3}'`
BASEDIR="${DATE}-PostgreSQL-${VERSION}-debug"
TAR_dbg="${DATE}-PostgreSQL-${VERSION}-debug.tar.gz"
mv build ${BASEDIR}
tar -zcf ${TAR_dbg} ${BASEDIR}
mv ${TAR_dbg} ${BASEDIR} ../
echo "Done!"