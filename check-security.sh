#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Please make sure your server is up and running before using this tool

# Internal variables: please do not change! Ref below for user configurable variables
RANDOM=`date +%s%N | cut -b14-19`                             # RANDOM: Random entropy pool init. RANDOMD (below): Random number generator (6 digits)
RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')
SCRIPT_PWD=$(cd `dirname $0` && pwd)

# User Configurable Variables
BASEDIR=/sda/Percona-Server-5.7.13-6-Linux.x86_64.ssl101
SOCKET=${BASEDIR}/socket.sock
CLIENT=${BASEDIR}/bin/mysql
USER="root"                                       # MySQL Username on the target host
PASSWORD=""                                       # Password on the target host
DATABASE=checksecurity                            # Database on the target host. Do not use any default included databases like 'test' or 'mysql' etc.

echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> /${WORKDIR}/pquery-run-direct.log; fi
}

# Trap ctrl-c
trap ctrl-c SIGINT
ctrl-c(){
  echoit "CTRL+C Was pressed. Terminating run..."
  echoit "Terminating check-security with exit code 2..."
  exit 2
}

# Environment check
if [ ! -r ${CLIENT} ]; then echoit "${CLIENT} is missing. Terminating."; exit 1; fi
if [ ! -r ${BASEDIR}/bin/mysqladmin ]; then echoit "${BASEDIR}/bin/mysqladmin is missing. Terminating."; exit 1; fi

# Check that server is up and running (has to be started before tool is used)
PWD=
if [ "$(${BASEDIR}/bin/mysqladmin -uroot -S${SOCKET} ping 2>/dev/null)" != "mysqld is alive" ]; then
  if [ "$(${BASEDIR}/bin/mysqladmin -uroot -phidden -S${SOCKET} ping 2>/dev/null)" != "mysqld is alive" ]; then
    echoit "The server with socket ${SOCKET} is not alive. Terminating."; exit 1;
  else
    PWD='-phidden'
  fi
fi

execute(){
  EXEC="${ROOTCLIENT} -e \"${1}\""
  eval ${EXEC}
}

# Commence testing
## Secure root
${CLIENT} 2>/dev/null -uroot ${PWD} -S${SOCKET} -B -f -e "DROP USER root@localhost;CREATE user root@localhost IDENTIFIED BY 'hidden';GRANT ALL ON *.* TO root@localhost WITH GRANT OPTION;FLUSH PRIVILEGES;"
## Setup testing database
${CLIENT} 2>/dev/null -uroot -phidden -S${SOCKET} -B -f -e "DROP DATABASE IF EXISTS ${DATABASE};CREATE DATABASE ${DATABASE};"
## Define clients
ROOTCLIENT="${CLIENT} -uroot -phidden -S${SOCKET} ${DATABASE} -B -f"
USERCLIENT="${CLIENT} -S${SOCKET} ${DATABASE} -B -f"
echoit "Creating 100000 users"
for seq in $(seq 0 100000); do
  execute "#DROP USER IF EXISTS 'u${seq}'@'localhost';\
CREATE USER 'u${seq}'@'localhost' IDENTIFIED BY '${seq}';\
GRANT USAGE ON ${DATABASE}.* TO 'u${sec}'@'localhost';\
FLUSH PRIVILEGES;"
  #eval ${USERCLIENT} -uu${sec}@localhost -p${sec} -e "SELECT 1;"
done
