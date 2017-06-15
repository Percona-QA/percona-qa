CLIENT_NAME=$1
TABLE_COUNT=$2
TABLE_SIZE=$3
WORKDIR="${PWD}"
MYSQL_USER=root


if [[ "${CLIENT_NAME}" == "ps" ]]; then
  BASEDIR=$(ls -1td ?ercona-?erver-5.* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"

elif [[ "${CLIENT_NAME}" == "ms" ]]; then
  BASEDIR=$(ls -1td mysql-5.* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"

elif [[ "${CLIENT_NAME}" == "pxc" ]]; then
  BASEDIR=$(ls -1td Percona-XtraDB-Cluster-5.* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"
fi

for i in $(sudo pmm-admin list | grep "mysql:metrics" | sed 's|.*(||;s|)||') ; do
	MYSQL_SOCK=${i}
  echo "Using MYSQL_SOCK=${MYSQL_SOCK}"
  ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create database pmm_stress_test"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TABLE_SIZE --oltp_tables_count=$TABLE_COUNT --mysql-db=pmm_stress_test --mysql-user=root  --num-threads=$TABLE_COUNT --db-driver=mysql --mysql-socket=${MYSQL_SOCK} prepare  2>&1 | tee $WORKDIR/sysbench_prepare.txt
  else
    sysbench /usr/share/sysbench/oltp_insert.lua --table-size=$TABLE_SIZE --tables=$TABLE_COUNT --mysql-db=pmm_stress_test --mysql-user=root  --threads=$TABLE_COUNT --db-driver=mysql --mysql-socket=${MYSQL_SOCK} prepare  2>&1 | tee $WORKDIR/sysbench_prepare.txt
  fi
done
