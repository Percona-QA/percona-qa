#!/usr/bin/bash

# Configuration Settings:

BASEDIR=/opt/percona-5.7
LD_LIBRARY_PATH=${BASEDIR}/lib
DATADIR1=${BASEDIR}/datadir
DATADIR2=${BASEDIR}/datadir2
DEFAULTS_FILE=${BASEDIR}/my.cnf
SOCKET1=${DATADIR1}/mysqld.sock
SOCKET2=${DATADIR2}/mysqld.sock
PORT1=3308
PORT2=3309
PID1=${DATADIR1}/new_mysql1.pid
PID2=${DATADIR2}/new_mysql2.pid
ERROR_LOG1=${DATADIR1}/error.log
ERROR_LOG2=${DATADIR2}/error.log
LIBJEMALLOC=/usr/lib64/libjemalloc.so.1
USER=root
MYSQL_USER=mysql
PASS=Baku12345#
BACKUP_DIR=/home/backup_dir/full
#TB_COMMAND="set tokudb_backup_dir='${BACKUP_DIR}'"
XB_PATH=/usr/local/xtrabackup/bin/
XB_COMMAND="${XB_PATH}/xtrabackup --defaults-file=${DEFAULTS_FILE} --backup --datadir=${DATADIR1} --target-dir=${BACKUP_DIR} --user=${USER} --password=${PASS} --no-version-check"
XB_PREPARE="${XB_PATH}/xtrabackup --defaults-file=${BACKUP_DIR}/backup-my.cnf --prepare --target-dir=${BACKUP_DIR}"
DUMP_FILE_PATH=/home/test_db
DUMP_FILE=/home/test_db/employees.sql

#################################################
#            INITIAL COMMANDS                   #
#################################################

# Starter commands for Percona Server with TokuDB&TokuBackup:

CMD1="${BASEDIR}/bin/mysqld_safe --defaults-file=${DEFAULTS_FILE} --user=${MYSQL_USER} --datadir=${DATADIR1} --socket=${SOCKET1} --port=${PORT1} --pid-file=${PID1} --malloc-lib=${LIBJEMALLOC}"

CMD2="${BASEDIR}/bin/mysqld_safe --defaults-file=${DEFAULTS_FILE} --user=${MYSQL_USER} --datadir=${DATADIR2} --socket=${SOCKET2} --port=${PORT2} --pid-file=${PID2} --malloc-lib=${LIBJEMALLOC}"

#echo ${CMD1}
#echo ${CMD2}

# RECOVER command

RCV="rsync -avrP ${BACKUP_DIR}/ ${DATADIR2}/"

# Consistency check command

CHCK="/usr/bin/mysqldbcompare --server1=${USER}:${PASS}@localhost:${PORT1}:${SOCKET1} --server2=${USER}:${PASS}@localhost:${PORT2}:${SOCKET2} --all --run-all-tests"


#################################################
#               WORKER FUNCTIONS                #
#################################################


# Function for STARTING Percona Server

start_main_mysql() {
	${CMD1} > /dev/null &
}


#Importing TokuDB tables

import_dump() {
	cd ${DUMP_FILE_PATH}
	${BASEDIR}/bin/mysql --user=${USER} --password=${PASS} --socket=${SOCKET1} --port=${PORT1} < ${DUMP_FILE}
}


# Function for Taking Backup

take_backup() {
	#${BASEDIR}/bin/mysql --user=${USER} --password=${PASS} --socket=${SOCKET1} --port=${PORT1} -e "${TB_COMMAND}" > /dev/null
	${XB_COMMAND}
	
}

# Function for Preparing Backup


prepare_backup() {
	${XB_PREPARE}
}


#Copy backup files to DATADIR2

copy_back() {
	${RCV} > /dev/null
}


# Starting secondary server:

start_secondary_mysql() {
	${CMD2} > /dev/null &
}


#mysqldbcompare --server1=root:12345@localhost:3308:/opt/percona-5.6.27/datadir/mysqld.sock --server2=root:12345@localhost:3309:/opt/percona-5.6.27/datadir2/mysqld.sock --all --run-all-tests

# Checking for data consistency between 2 servers

compare_data() {
	#echo "/usr/bin/mysqldbcompare --server1=${USER}:${PASS}@localhost:${PORT1}  --server2=${USER}:${PASS}@localhost:${PORT2}  --all  --run-all-tests"
	/usr/bin/mysqldbcompare --server1=${USER}:${PASS}@localhost:${PORT1}  --server2=${USER}:${PASS}@localhost:${PORT2}  --all  --run-all-tests
}


# Function for cleaning environment before test
clean_environment() {

	echo "Killing running mysqld processes"
	pkill -9 -f mysqld
	sleep 5

	if [ -d ${BACKUP_DIR} ]; then
		rm -rf ${BACKUP_DIR}
	fi

	if [ -d ${DATADIR2} ]; then
		rm -rf ${DATADIR2}
	fi
	echo "Cleaned!"
}



#################################################
#               RUN ALL                         #
#################################################

clean_environment

##

start_main_mysql

if [[ $? -ne 0 ]] ; then
    echo "Start - Failed!"
    exit 1
else
	echo "Started Main Percona Server - OK!"
	sleep 5
fi

import_dump

if [[ $? -ne 0 ]] ; then
    echo "Importing of Sample Schema - Failed!"
    exit 1
else
	echo "Imported Sample Schema      - OK!"
	sleep 5
fi

# Check for backup directory

if [ ! -d ${BACKUP_DIR} ]; then
	mkdir ${BACKUP_DIR}
	chown mysql:mysql ${BACKUP_DIR}
else
	chown mysql:mysql ${BACKUP_DIR}
fi;

take_backup

if [[ $? -ne 0 ]] ; then
    echo "Backup - Failed!"
    exit 1
else
	echo "Backup Completed             - OK!"
fi

prepare_backup

if [[ $? -ne 0 ]] ; then
    echo "Backup Prepare - Failed!"
    exit 1
else
	echo "Backup Prepare Completed             - OK!"
fi

#Copying taken backup to DATADIR2
#Check for DATADIR2
if [ ! -d ${DATADIR2} ]; then
	mkdir ${DATADIR2}
	chown -R mysql:mysql ${DATADIR2}
else
	chown -R mysql:mysql ${DATADIR2}
fi;

copy_back

if [[ $? -ne 0 ]] ; then
    echo "Copy action Failed!"
    exit 1
else
	echo "Copied backup to new datadir - OK!"
fi

chown -R mysql:mysql ${DATADIR2}

start_secondary_mysql

if [[ $? -ne 0 ]] ; then
    echo "Starting Secondary Server - Failed!"
    exit 1
else
	echo "Started Secondary Percona Server- OK!"
	sleep 10
fi

compare_data

if [[ $? -ne 0 ]] ; then
    echo "Compare command - Failed!"
    exit 1
else
	echo "Compare Command - OK! , Check Status"
fi