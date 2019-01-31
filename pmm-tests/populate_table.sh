CLIENT_NAME=$1
TABLE_COUNT=$2
TABLE_SIZE=$3
VERSION=$4
WORKDIR="${PWD}"
MYSQL_USER=root


if [[ "${CLIENT_NAME}" == "ps" ]]; then
  BASEDIR=$(ls -1td [Pp]ercona-[Ss]erver-${VERSION}* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"

elif [[ "${CLIENT_NAME}" == "ms" ]]; then
  BASEDIR=$(ls -1td mysql-${VERSION}* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"

elif [[ "${CLIENT_NAME}" == "pxc" ]]; then
  BASEDIR=$(ls -1td Percona-XtraDB-Cluster-${VERSION}* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"

elif [[ "${CLIENT_NAME}" == "md" ]]; then
  BASEDIR=$(ls -1td mariadb-${VERSION}* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"
fi

if [[ "${CLIENT_NAME}" == "pxc" ]]; then
  MYSQL_SOCK=$(sudo pmm-admin list | grep 'mysql:metrics[ \t].*_NODE-' | awk -F[\(\)] '{print $2}' | head -n 1)
  echo "Using MYSQL_SOCK=${MYSQL_SOCK}"
  ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create database pmm_stress_test"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TABLE_SIZE --oltp_tables_count=$TABLE_COUNT --mysql-db=pmm_stress_test --mysql-user=root  --num-threads=$TABLE_COUNT --db-driver=mysql --mysql-socket=${MYSQL_SOCK} prepare  2>&1 | tee $WORKDIR/sysbench_prepare.txt
  else
    sysbench /usr/share/sysbench/oltp_insert.lua --table-size=$TABLE_SIZE --tables=$TABLE_COUNT --mysql-db=pmm_stress_test --mysql-user=root  --threads=$TABLE_COUNT --db-driver=mysql --mysql-socket=${MYSQL_SOCK} prepare  2>&1 | tee $WORKDIR/sysbench_prepare.txt
  fi
else
  for i in $(sudo pmm-admin list | grep 'mysql:metrics[ \t].*_NODE-' | awk -F[\(\)] '{print $2}') ; do
  	MYSQL_SOCK=${i}
    echo "Using MYSQL_SOCK=${MYSQL_SOCK}"
    ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create database pmm_stress_test"
    if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
      sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TABLE_SIZE --oltp_tables_count=$TABLE_COUNT --mysql-db=pmm_stress_test --mysql-user=root  --num-threads=$TABLE_COUNT --db-driver=mysql --mysql-socket=${MYSQL_SOCK} prepare  2>&1 | tee $WORKDIR/sysbench_prepare.txt
    else
      sysbench /usr/share/sysbench/oltp_insert.lua --table-size=$TABLE_SIZE --tables=$TABLE_COUNT --mysql-db=pmm_stress_test --mysql-user=root  --threads=$TABLE_COUNT --db-driver=mysql --mysql-socket=${MYSQL_SOCK} prepare  2>&1 | tee $WORKDIR/sysbench_prepare.txt
    fi
  done
fi
