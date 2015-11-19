#!/usr/bin/bash

# Configuration Settings:

BASEDIR=/opt/percona-5.6.27
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
PASS=12345
BACKUP_DIR=/home/tokubackupdir
TB_COMMAND="set tokudb_backup_dir='${BACKUP_DIR}'"
DUMP_FILE=/home/employees_tokudb.sql


# Starter commands for Percona Server with TokuDB&TokuBackup:

CMD1="${BASEDIR}/bin/mysqld_safe --defaults-file=${DEFAULTS_FILE} --user=${USER} --datadir=${DATADIR1} --socket=${SOCKET1} --port=${PORT1} --pid-file=${PID1} --malloc-lib=${LIBJEMALLOC}"

CMD2="${BASEDIR}/bin/mysqld_safe --defaults-file=${DEFAULTS_FILE} --user=${USER} --datadir=${DATADIR12} --socket=${SOCKET2} --port=${PORT2} --pid-file=${PID2} --malloc-lib=${LIBJEMALLOC}"


# RECOVER command

RCV="rsync -avrP ${BACKUP_DIR} ${DATADIR2}"

# Function for STARTING Percona Server

start_main_mysql() {
	${CMD1} > /dev/null & 
	echo "Started Percona Server!"
}

# Start PS for backup
#start_main_mysql


#Importing DUMP

import_dump() {
	echo "Importing sample TokuDB schema"
	${BASEDIR}/bin/mysql --user=${USER} --password=${PASS} --socket=${SOCKET1} --port=${PORT1} < ${DUMP_FILE}
}

import_dump


# Check for backup directory

if [ ! -d ${BACKUP_DIR} ]; then
	mkdir ${BACKUP_DIR}
	chown mysql:mysql ${BACKUP_DIR}
else
	chown mysql:mysql ${BACKUP_DIR}
fi;



# Function for Taking Backup

take_backup() {
	echo "Taking Backup Using TokuBackup!"
	${BASEDIR}/bin/mysql --user=${USER} --password=${PASS} --socket=${SOCKET1} --port=${PORT1} -e "${TB_COMMAND}"
	
}

take_backup
 