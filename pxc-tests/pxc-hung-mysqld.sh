#!/bin/bash

#PXC- record_hung_mysqld.sh
SCRIPT_PWD=$(cd `dirname $0` && pwd)

tstamp=`date +'%Y%m%d%H%M%S'`
pid=`ps -ewwo '%p %c' | grep 'mysqld$' |  sed 's/^ //g' | cut -d' ' -f1`
hname=`hostname`
dirname="/ssd/pxc_test/${hname}_hung_${tstamp}"

mkdir ${dirname}
cd ${dirname}

(
  rpm -qa | grep percona; \
  ls -1 /usr/sbin/mysqld  /usr/lib64/galera3/libgalera_smm.so  | \
    xargs -n1 -i^ /bin/bash -c 'ls -l ^; md5sum ^' ) > bins.txt

cp /var/lib/mysql/error.log .

gdb /usr/sbin/mysqld ${pid} < ${SCRIPT_PWD}/hung_mysqld.gdb | tee gdb.out

gcore -o core_mysqld_${hname}_${tstamp} ${pid}

