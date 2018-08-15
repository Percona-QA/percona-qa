#!/bin/bash
# Created by Roel Van de Paar, Percona LLC
# With thanks to http://unix.stackexchange.com/questions/47271/prevent-gnu-screen-from-terminating-session-once-executed-script-ends (jw013)

# User variables
BASEDIR=/sda/MS300718-mysql-8.0.12-linux-x86_64-debug
WORKDIR=/sda
THREADS=1
STATIC_PQUERY_BIN=/home/roel/percona-qa/pquery/pquery2-ps8  # Leave empty to use a random binary, i.e. percona-qa/pquery/pquery*
SESSIONS=15

# Internal variables: Do not change!
SCRIPT_PWD=$(cd `dirname $0` && pwd)

# Trap ctrl-c
trap ctrl-c SIGINT

ctrl-c(){
  # Silently restore the original pquery-reach.sh settings
  restore-pqr-settings
}

restore-pqr-settings(){
  if [ "${BACKUP_BASEDIR}" != "" ]; then
    sed -i "s|^[ \t]*BASEDIR=.*|BASEDIR=${BACKUP_BASEDIR}|" ${SCRIPT_PWD}/pquery-reach.sh
    sed -i "s|^[ \t]*WORKDIR=.*|WORKDIR=${BACKUP_WORKDIR}|" ${SCRIPT_PWD}/pquery-reach.sh
    sed -i "s|^[ \t]*THREADS=.*|THREADS=${BACKUP_THREADS}|" ${SCRIPT_PWD}/pquery-reach.sh
    sed -i "s|^[ \t]*STATIC_PQUERY_BIN=.*|STATIC_PQUERY_BIN=${BACKUP_STATICP}|" ${SCRIPT_PWD}/pquery-reach.sh
  fi
}

echoit(){
  echo "[$(date +'%T')] === $1"
}

if [ ! -r ${SCRIPT_PWD}/pquery-reach.sh ]; then
  echoit "Assert! ${SCRIPT_PWD}/pquery-reach.sh not found!"
  exit 1
fi

# Backup current settings (restored on script-end as well as when ctrl+c is pressed)
BACKUP_BASEDIR="$(grep "^[ \t]*BASEDIR=" ${SCRIPT_PWD}/pquery-reach.sh | head -n1 | sed 's|[ \t]*BASEDIR=||')"
BACKUP_WORKDIR="$(grep "^[ \t]*WORKDIR=" ${SCRIPT_PWD}/pquery-reach.sh | head -n1 | sed 's|[ \t]*WORKDIR=||')"
BACKUP_THREADS="$(grep "^[ \t]*THREADS=" ${SCRIPT_PWD}/pquery-reach.sh | head -n1 | sed 's|[ \t]*THREADS=||')"
BACKUP_STATICP="$(grep "^[ \t]*STATIC_PQUERY_BIN=" ${SCRIPT_PWD}/pquery-reach.sh | head -n1 | sed 's|[ \t]*STATIC_PQUERY_BIN=||')"

# Set new basedir and threads as per settings above
sed -i "s|^[ \t]*BASEDIR=.*|BASEDIR=${BASEDIR}|" ${SCRIPT_PWD}/pquery-reach.sh
sed -i "s|^[ \t]*WORKDIR=.*|WORKDIR=${WORKDIR}|" ${SCRIPT_PWD}/pquery-reach.sh
sed -i "s|^[ \t]*THREADS=.*|THREADS=${THREADS}|" ${SCRIPT_PWD}/pquery-reach.sh
sed -i "s|^[ \t]*STATIC_PQUERY_BIN=.*|STATIC_PQUERY_BIN=${STATIC_PQUERY_BIN}|" ${SCRIPT_PWD}/pquery-reach.sh

for i in $(seq 1 $SESSIONS); do
  echoit "Starting pquery-reach.sh screen session #${i}..."
  screen -dmS p${i} sh -c "${SCRIPT_PWD}/pquery-reach.sh; exec bash"
done

restore-pqr-settings

echo "Done!"
echo "* Use screen -ls to see a list of active screen sessions"
echo "* Use screen -d -r p{nr} (where {nr} is the screen session you want) to reconnect to an individual screen session"
echo -e "\nList of sessions active:"
screen -ls
