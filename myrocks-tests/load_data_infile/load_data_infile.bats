#!/usr/bin/env bats
# Created by Tomislav Plavcic from Percona LLC
# mysqld needs to be started with --secure-file-priv=datadir or --secure-file-priv=

WORKDIR="${PWD}"
BASEDIR=$(ls -1td ${WORKDIR}/PS* | grep -v ".tar" | grep PS[0-9])
DATADIR=${BASEDIR}/data
CONNECTION=$(cat ${BASEDIR}/cl_noprompt_nobinary)
DIRNAME=$BATS_TEST_DIRNAME

#CONNECTION=${CONNECTION:---socket=/var/run/mysqld/mysqld.sock -uroot}
#MYSQL_BIN=${MYSQL_BIN:-/usr/bin/mysql}
#DATADIR=${DATADIR:-/var/lib/mysql}

@test "create initial tables" {
  for storage in InnoDB RocksDB; do
    $(cat ${DIRNAME}/create_table.sql | sed "s/@@SE@@/${storage}/g" | ${CONNECTION})
    echo $output
    [ $? -eq 0 ]
  done
}

@test "load initial data" {
  $(cp ${DIRNAME}/t*.data ${DATADIR})
  for storage in InnoDB RocksDB; do
    for table in t1 t2 t3; do
      $(${CONNECTION} --database=load_data_infile_test -e "LOAD DATA INFILE \"${DATADIR}/${table}.data\" INTO TABLE load_data_infile_test.${table}_${storage} FIELDS TERMINATED BY '\t';")
      echo $output
      [ $? -eq 0 ]
    done
  done
  $(rm -f ${DATADIR}/t*.data)
}

@test "check table checksum" {
  for storage in InnoDB RocksDB; do
    for table in t1 t2 t3; do
      if [ ${table} = "t1" ]; then
        checksum_initial="2553511941";
      elif [ ${table} = "t2" ]; then
        checksum_initial="4192795574";
      else
        checksum_initial="1629576163";
      fi
      checksum="$(${CONNECTION} --database=load_data_infile_test -e "CHECKSUM TABLE load_data_infile_test.${table}_${storage};" --skip-column-names -E|tail -n1)"
      echo $output
      [ $? -eq 0 ]
      [ "${checksum_initial}" -eq "${checksum}" ]
    done
  done
}

@test "select into outfile" {
  for storage in InnoDB RocksDB; do
    for table in t1 t2 t3; do
      run ${CONNECTION} --database=load_data_infile_test -e "SELECT * INTO OUTFILE \"${DATADIR}/${table}_${storage}.data\" FIELDS TERMINATED BY ',' FROM load_data_infile_test.${table}_${storage};"
      echo $output
      [ $status -eq 0 ]
    done
  done
}

@test "check file diff" {
  for table in t1 t2 t3; do
    run diff ${DATADIR}/${table}_InnoDB.data ${DATADIR}/${table}_RocksDB.data
    echo $output
    [ $status -eq 0 ]
    $(rm -f ${DATADIR}/${table}_*.data)
  done
}
