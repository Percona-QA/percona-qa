#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script quickly tests all available mysqld options
# Possible improvements:
# - Auto-scan for correct core file naming syntax (ref OS), or get results from using --core-file to mysqld or something (scan for core.*)
# - See 'TODO' below re: combinatorics or intelligent option/value combinations

# This script is deprecated in two ways: fully deprecated for TEST_OR_GENERATE=1, and semi-deprecated for TEST_OR_GENERATE=0:
# 1) The TEST_OR_GENERATE=1 option was added to generate a list of all options to use in combination with pquery-run.sh, but while this works, the quality of the generated
#    possibilities is rather low, resulting in many pqury-run.sh trial failures. Hence, generate_mysqld_options.sh was born, which is much more intelligent (and semi-manual)
# 2) The TEST_OR_GENERATE=0 option still works fine, and if you have a spare machine to run this script on for a long time you can test all mysqld options at mysqld startup
#    (i.e. more or less the original function of this script). However, as pquery-run.sh now encapulates the mysqld option testing functionality, the offset between this
#    script and the updated pquery-run.sh is minimal. The only advantage that this script offers is that it is likely (TBD) somewhat better in handling/capturing mysqld
#    startup failures/crashes then pquery-run.sh is (as pquery-run.sh will simply assume that there is a startup failure).
# Overall recommendation: unless you have spare hardware to run this on for (for example for a few days, or even two weeks or more), stick with pquery-run.sh for the moment. Still, it is able to quickly test all mysqld options, so for major GA releases it makes sense to run this script, especially the first layers (options > options with a single value set)

if [ ! -r ./bin/mysqld ]; then
  if [ ! -r ./mysqld ]; then
    echo "This script quickly tests or generates all mysqld options using various option values in combination therewith"
    echo "Note that - when using testing mode (i.e. TEST_OR_GENERATE=0), it expects cores to be written to /cores/core.pid. Location can be changed in-script, but not filename"
    echo "To set your server up in this way (in terms of corefile generation), see core file setting part of setup_server.sh, available at lp:percona-qa"
    echo "Error: no ./bin/mysqld or ./mysqld found!"
    exit 1
  else
    cd ..
  fi
fi

# User Variables
MYEXTRA="--log-bin --server-id=0 --plugin-load=TokuDB=ha_tokudb.so --tokudb-check-jemalloc=0 --plugin-load-add=RocksDB=ha_rocksdb.so"  # Note that currently MYEXTRA is only used for runs where the data dir does NOT have the msyql_install_db binary in place (i.e. newer versions), irrespective of whetter mysqld accepts --initialize-insecure or not (this can be improved by testing to see if --initialize-insecure can be used, and if so, skip on mysqld_install_db, or check if mysql_install_db accepts MYEXTRA passing
TEST_OR_GENERATE=0  # If 0, the options will be tested against mysqld, if 1, they will simply be generated and written to file (for use with pquery-run.sh)
                    # To generate options for pquery-run.sh (ref ADD_RANDOM_OPTIONS=1 setting in pquery-run.sh), use MAX_LEVELS=1 as pquery has min/max NR_OF_RANDOM_OPTIONS_TO_ADD
MAX_LEVELS=4        # Maxium amount of depth to test. Set to 0 for max depth. If MAX_LEVELS=1 then mysqld will be tested with only one --option addition. =2 then two options etc.
                    # Note that with the current number of option values (22) & approx number of mysqld parameters (488) a MAX_LEVELS=1 is 10,736 combinations.
                    # With two levels exhaustively testing this becomes 488*22*488*22 (each option with each value combined with each option with each value) = 115,261,696 comb.
                    # With 4 levels (the currently implemented maximum) this becomes an e+20 number. Clearly combinatorics would help here. <TODO
                    # Another option would be to define per-option the sensible value ranges and select only a few values per option that make sense <TODO

# Option values array ('' = use option without a value, which works for non-value options, for example; --core-file)
# declare -a VALUES=('' '-1' '0' '1' '2' '10' '240' '1026' '-1125899906842624' '1125899906842624' 'a' '&&1' '%' 'NONE' '-NULL' 'NULL' '.' '..' '/tmp' '/tmp/nofile' '/' 't1') #old
declare -a VALUES=('' '0' '1' '2' '10' '240' '-1125899906842624' '1125899906842624' 'NONE' 'NULL' '/tmp' '/tmp/nofile' '/' 't1')  # new, for more smoother pquery-run.sh runs

# Vars
MYSQLD_START_TIMEOUT=10  # Default: 30, but this may be tuned down on non-loaded servers with single threaded testruns. Increase when there is more load.
RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(.......\).*/\1/')
WORKDIR=/sda/${RANDOMD}  # Here we keep the log files, option list, failed items
RUNDIR=/dev/shm/${RANDOMD}  # Here we keep a copy of the data template dir and here we do the actual mysqld runs (--datadir=...). Not required for TEST_OR_GENERATE=1 runs
FINDS="^Error:|ERROR|allocated at line|missing DBUG_RETURN|^safe_mutex:|Invalid.*old.*table or database|InnoDB: Warning|InnoDB: Error:|InnoDB: Operating system error|Error while setting value"
IGNOR="Lock wait timeout exceeded|Deadlock found when trying to get lock|innodb_log_block_size has been changed|Sort aborted:|ERROR: the age of the last checkpoint is [0-9]*,|consider increasing server sort buffer size|.ERROR. Event Scheduler:.*does[ ]*n.t exist"
CORES=0

echoit(){
  if [ ${TEST_OR_GENERATE} -eq 0 ]; then
    echo "[$(date +'%T')] [$CORES] [${OPTIONS}] $1"
    echo "[$(date +'%T')] [$CORES] [${OPTIONS}] $1" >> /${WORKDIR}/test_mysqld_options.log
  else
    echo "[$(date +'%T')] $1"
    echo "[$(date +'%T')] $1" >> /${WORKDIR}/test_mysqld_options.log
  fi
}

test_options(){
  echoit "Ensuring there are no relevant servers running..."
  KILLPID=$(ps -ef | grep "${RUNDIR}" | grep -v grep | awk '{print $2}' | tr '\n' ' ')
  (sleep 0.2; kill -9 ${KILLPID} >/dev/null 2>&1) &
  wait $KILLDPID >/dev/null 2>&1  # The sleep 0.2 + subsequent wait (cought before the kill) avoids the annoying 'Killed' message
                                  # from being displayed in the output. Thank you to user 'Foonly' @ forums.whirlpool.net.au
  echoit "Clearing rundir..."
  rm -Rf ${RUNDIR}/data/* ${RUNDIR}/log/* ${RUNDIR}/pid.pid ${RUNDIR}/socket.sock
  echoit "Generating new workdir..."
  mkdir -p ${RUNDIR}/data/test ${RUNDIR}/data/mysql ${RUNDIR}/log
  echoit "Copying datadir from template..."
  cp -R ${RUNDIR}/data.template/* ${RUNDIR}/data
  PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
  echoit "Starting mysqld..."
  CMD="./bin/mysqld ${MYEXRA} --basedir=${PWD} --datadir=${RUNDIR}/data --core-file \
                    --port=${PORT} --pid_file=${RUNDIR}/pid.pid --socket=${RUNDIR}/socket.sock \
                    --log-error=${RUNDIR}/log/master.err ${OPTIONS}"
  ${CMD} >> ${RUNDIR}/log/master.err 2>&1 &
  MPID="$!"
  # Give up to 30 seconds for mysqld to start, but check intelligently for known startup issues like "Error while setting value" for options
  echoit "Waiting for mysqld (pid: ${MPID}) to fully start..."
  BADVALUE=0
  for X in $(seq 0 $MYSQLD_START_TIMEOUT); do
    sleep 1
    if ./bin/mysqladmin -uroot -S${RUNDIR}/socket.sock ping > /dev/null 2>&1; then
      break
    fi
    if egrep -qi "Error while setting value" ${RUNDIR}/log/master.err; then
      BADVALUE=1
      break
    elif [ "${MPID}" == "" ]; then
      echo_it "Assert! ${MPID} empty"
      exit 1
    fi
  done

  if [ ${BADVALUE} -eq 1 ]; then
    echoit "=== Fail: An option value is reported to be erroneous by mysqld."
  else
    # Check if mysqld is alive
    if ./bin/mysqladmin -uroot -S${RUNDIR}/socket.sock ping > /dev/null 2>&1; then
      echoit "Server started ok. Now checking results..."
      if egrep -qi "value.*adjusted to" ${RUNDIR}/log/master.err; then
        echoit "=== Modified: an option value was modified by mysqld."
      elif egrep -qi "ignoring option.*due to invalid value" ${RUNDIR}/log/master.err; then
        echoit "=== Ignored: an option value was ignored by mysqld."
      elif egrep -qi "option.*value.*wasn't recognized" ${RUNDIR}/log/master.err; then
        echoit "=== Not recognized: an option value was not recognized by mysqld."
      else
        echoit "=== Success: option (set) worked OK!"
      fi
    else
      echoit "Server failed to start correctly. Checking if there is a coredump for the PID..."
      sleep 2  # Delay to ensure core was written completely
      if [ $(ls -l ${RUNDIR}/data/*core* 2>/dev/null | wc -l) -ge 1 ]; then
        CORES=$[ $CORES + 1 ]
        echoit "=== !!! Fail: an option failed and generated a core at $(ls ${RUNDIR}/data/*core*)"
        echoit "Copying vardir from ${RUNDIR}/data to ${WORKDIR}/data.${MPID}"
        mv ${RUNDIR}/data ${WORKDIR}/data.${MPID}
        mv ${RUNDIR}/log ${WORKDIR}/log.${MPID}
      else
        echoit "=== ??? Fail: an option failed, but did not generate a core. Relevant error log content:"
        egrep "${FINDS}" ${RUNDIR}/log/master.err | grep -v "${IGNOR}" | sed 's|^|^  |'
        egrep "${FINDS}" ${RUNDIR}/log/master.err | grep -v "${IGNOR}" | sed 's|^|^  |' >> /${WORKDIR}/test_mysqld_options.log
      fi
    fi
  fi
}

# Setup
if [ ${TEST_OR_GENERATE} -eq 0 ]; then
  rm -Rf ${WORKDIR} ${RUNDIR}
  mkdir ${WORKDIR} ${RUNDIR}
  echoit "Mode: mysqld option testing | Workdir: ${WORKDIR} | Rundir: ${RUNDIR}"
  echoit "Basedir: ${PWD}"
  echoit "MYEXTRA: ${MYEXTRA}"
  echoit "Generating initial rundir subdirectories..."
  if [ -r ./bin/mysql_install_db ]; then
    mkdir -p ${RUNDIR}/data/test ${RUNDIR}/data/mysql ${RUNDIR}/log
    echoit "Generating datadir template (using mysql_install_db)..."
    ./bin/mysql_install_db --no-defaults --force --basedir=${PWD} --datadir=${RUNDIR}/data > ${WORKDIR}/mysql_install_db.txt 2>&1
  elif [ -r ./scripts/mysql_install_db ]; then
    mkdir -p ${RUNDIR}/data/test ${RUNDIR}/data/mysql ${RUNDIR}/log
    echoit "Generating datadir template (using mysql_install_db)..."
    ./scripts/mysql_install_db --no-defaults --force --basedir=${PWD} --datadir=${RUNDIR}/data > ${WORKDIR}/mysql_install_db.txt 2>&1
  else  # This needs to become an elif and the else below needs to be renealed
    mkdir -p ${RUNDIR}/log
    echoit "Generating datadir template (using mysqld --initialize-insecure)..."
    ./bin/mysqld --no-defaults --initialize-insecure ${MYEXTRA} --basedir=${PWD} --datadir=${RUNDIR}/data > ${WORKDIR}/mysqld_initalize.txt 2>&1
  #else
  #  echo "Error: mysql_install_db not found in ${PWD}/scripts nor in ${PWD}/bin"
  #  exit 1
  fi
  mv ${RUNDIR}/data ${RUNDIR}/data.template
else
  rm -Rf ${WORKDIR}
  mkdir ${WORKDIR}
  echoit "Mode: mysqld option generation | Workdir: ${WORKDIR} | Basedir: ${PWD}"
  echoit "Writing all generated option combinations to ${WORKDIR}/full_generated_mysqld_options_list.txt..."
fi

# Fetch mysqld options
echoit "Fetching options from mysqld"
./bin/mysqld --help --verbose 2>&1 | grep "^  --[a-z]" | sed 's|^  ||;s| .*||;s|=#||;s|\[=name\]||;s|\[\]||;s|=name||' > /${WORKDIR}/mysqld_options.txt

option_add(){
  if [ "$2" == "" ]; then
    OPTIONS="${OPTIONS}$1 "
  else
    OPTIONS="${OPTIONS}$1=$2 "
  fi
}

# Start actual option testing, combinations up to 4 options supported (and easy to expand)
if [ ${TEST_OR_GENERATE} -eq 0 ]; then
  echoit "Starting option/value testing iterations"
else
  echoit "Starting option/value generation iterations"
fi
COUNT=0
COUNT_GEN=0
LEVEL=1
for VALUE4 in "${VALUES[@]}"; do
  for OPTION4 in $(cat ${WORKDIR}/mysqld_options.txt); do
    for VALUE3 in "${VALUES[@]}"; do
      for OPTION3 in $(cat ${WORKDIR}/mysqld_options.txt); do
        for VALUE2 in "${VALUES[@]}"; do
          for OPTION2 in $(cat ${WORKDIR}/mysqld_options.txt); do
            for VALUE1 in "${VALUES[@]}"; do
              for OPTION1 in $(cat ${WORKDIR}/mysqld_options.txt); do
                OPTIONS=""
                COUNT=$[ ${COUNT} + 1 ]
                if [ ${TEST_OR_GENERATE} -eq 0 ]; then
                  if [ ${COUNT} -ge 10 ]; then  # Periodical reporting of workdir
                    COUNT=0
                    echoit "Periodical reporting: Workdir: ${WORKDIR} | Rundir: ${RUNDIR}"
                  fi
                else
                  COUNT_GEN=$[ ${COUNT_GEN} + 1 ]
                  if [ ${COUNT} -ge 1000 ]; then  # Periodical reporting of generated number of optins counter
                    COUNT=0
                  #if [ "$(echo ${COUNT} | sed 's|^[1-9]*||' | sed 's|.*\(...\)|\1|')" == "000" ]; then  # Periodical reporting of generated number of optins counter
                    echoit "Periodical reporting: Options generated: ${COUNT_GEN} | Level: ${LEVEL} | Result file: ${WORKDIR}/full_generated_mysqld_options_list.txt"
                  fi
                fi
                if [ ${LEVEL} -ge 4 ]; then
                  option_add ${OPTION4} ${VALUE4}
                fi
                if [ ${LEVEL} -ge 3 ]; then
                  option_add ${OPTION3} ${VALUE3}
                fi
                if [ ${LEVEL} -ge 2 ]; then
                  option_add ${OPTION2} ${VALUE2}
                fi
                option_add ${OPTION1} ${VALUE1}
                OPTIONS=$(echo ${OPTIONS} | sed 's|[ ]*$||')
                if [ ${TEST_OR_GENERATE} -eq 0 ]; then
                  test_options
                else
                  echo "${OPTIONS}" >> ${WORKDIR}/full_generated_mysqld_options_list.txt
                fi
                # Debug
                # read -p "Press enter to continue..."
              done
            done
            if [ ${MAX_LEVELS} -eq 1 ]; then echoit "Done!"; exit 0; fi
            LEVEL=2
          done
        done
        if [ ${MAX_LEVELS} -eq 2 ]; then echoit "Done!"; exit 0; fi
        LEVEL=3
      done
    done
    if [ ${MAX_LEVELS} -eq 3 ]; then echoit "Done!"; exit 0; fi
    LEVEL=4
  done
done
