#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

RND_DELAY_FUNCTION=0     # If set to 1, insert random delays after starting a new repetition in a thread. This may help to decrease locking issues.

if [ "" == "$5" ]; then
  echo "This script expects exactly 5 options. Execute as follows:"
  echo "$ multirun_cli.sh threads repetitions input.sql cli_binary socket"
  echo "Where:"
  echo "  threads: is the number of simultaneously started cli threads"
  echo "  repetitions: the number of repetitions *per* individual thread"
  echo "  input.sql: is the input SQL file executed by the clients"
  echo "  cli_binary: is the location of the mysql binary"
  echo "  socket: is the location of the socket file for connection to mysqld"
  echo "Example:"
  echo "$ multirun_cli.sh 10 5 bug.sql /ssd/percona-server-5.5/bin/mysql /ssd/testing/socket.sock"
  echo "Cautionary Notes:"
  echo "  - Script does not check *yet* if options passed are all valid/present, make sure you get it right"
  echo "  - If root user uses a password, a script hack is suggested *ftm*"
  echo "  - This script may cause very significant server load if used with many threads"
  echo "  - This script expects write permissions in the current directory ($PWD)"
  echo "  - Output files for each thread are written as: multirun.<thread number>.<repetition number> (e.g. multirun.1.1 etc.)"
  exit 1
fi

EXE_TODO=$[$1 * $2]
EXE_DONE=0
echo "===== Total planned executions:"
echo "$1 Thread * $2 Repetitions = $EXE_TODO Executions"

echo -e "\n===== Reseting all threads statuses"
for (( thread=1; thread<=$1; thread++ )); do
  PID[$thread]=0
  RPT_LEFT[$thread]=$2
done
echo "Done!"

echo -e "\n===== Verifying server is up & running"
if [ -r "${4}admin" ]; then
  CHK_CMD="${4}admin -uroot -S$5 ping >/dev/null 2>&1"
  if ! eval ${CHK_CMD}; then
    echo "Server not reachable! Check settings."
    echo "Terminating!"
    exit 1
  fi
fi

echo -e "\n===== Starting CLI processes"
for (( ; ; )); do
  # Loop through threads
  for (( thread=1; thread<=$1; thread++ )); do
    # Check if thread is busy
    if [ ${PID[$thread]} -eq 0 ]; then
      # Check if repeats are exhaused
      if [ ${RPT_LEFT[$thread]} -ne 0 ]; then
        REPETITION=$[ $2 - ${RPT_LEFT[$thread]} + 1 ]
        echo -n "Thread: $thread | Repetition: ${REPETITION}/$2 | "
        CLI_CMD="$4 -uroot -S$5 -f < $3 > multirun.$thread 2>&1"
        # For testing: CLI_CMD="sleep $[ $RANDOM % 10 ]"
        eval ${CLI_CMD} &
        PID[$thread]=$!
        echo "Started! [PID: ${PID[$thread]}]"
        RPT_LEFT[$thread]=$[ ${RPT_LEFT[$thread]} - 1 ]
        # Check to see if server is still alive - provided mysqladmin can be found in same location as mysql binary
        if [ -r "${4}admin" ]; then
          CHK_CMD="${4}admin -uroot -S$5 ping >/dev/null 2>&1"
          if ! eval ${CHK_CMD}; then
            echo "Server no longer reachable! Check for crash etc."
            echo "Terminating!"
            exit 1
          fi
        fi
        # Introduce random delay if set to do so
        if [ $RND_DELAY_FUNCTION -eq 1 -a $thread -ne $1 ]; then
          RND_DELAY=$[ $RANDOM % 10 ]
          echo -n "   Random delay: $RND_DELAY seconds | "
          eval "sleep $RND_DELAY"
          echo "Done!"
        fi
      fi
    else
      if [ -z "`ps -p ${PID[$thread]} | awk '{print $1}' | grep -v 'PID'`" ]; then
        echo -e "\t\t\t\t\t\t   Thread: $thread | Repetition: $[ $2 - ${RPT_LEFT[$thread]} ]/$2 | [PID: ${PID[$thread]}] Ended!"
        EXE_DONE=$[ $EXE_DONE + 1 ]
        PID[$thread]=0
      fi
    fi
  done
  if [ $EXE_DONE -ge $EXE_TODO ]; then break; fi
done
