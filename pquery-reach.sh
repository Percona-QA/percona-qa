#!/bin/bash
# Created by Roel Van de Paar, Percona LLC
# Updated to work with latest pquery framework structure (as of 13-08-2018)

# User variables
BASEDIR=   # Likely already set in pquery-reach++.sh when using that
THREADS=1
WORKDIR=/dev/shm
COPYDIR=/sda
STATIC_PQUERY_BIN=/home/roel/percona-qa/pquery/pquery2-ps8  # Leave empty to use a random binary, i.e. percona-qa/pquery/pquery*
#MYINIT="--early-plugin-load=keyring_file.so --keyring_file_data=keyring --innodb_sys_tablespace_encrypt=ON"    # Variables to add to MID (MySQL init) (changes INIT_OPT in pquery-run.sh)
#MYEXTRA="--early-plugin-load=keyring_file.so --keyring_file_data=keyring --innodb_sys_tablespace_encrypt=ON"  # Variables to add to pquery run
MYINIT=
MYEXTRA=
EARLYCOPY=0  # Make a copy to the COPYDIR before starting reducer. Not strictly required, but handy if your machine may power off and you were using /dev/shm as WORKDIR

# Internal variables: Do not change!
RANDOM=`date +%s%N | cut -b14-19`; 
RANDOMR=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(.......\).*/\1/')  # Create random dir nr | 7 digits to separate it from other runs
RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')   # Create random dir/file nr
SCRIPT_PWD=$(cd `dirname $0` && pwd)
RUN_DONE=0

echoit(){
  echo "[$(date +'%T')] === $1"
  if [ "${WORKDIR}" != "" ]; then 
    if [ ${RUN_DONE} -ne 1 ]; then
      echo "[$(date +'%T')] === $1" >> ${PQUERY_REACH_LOG}
    else
      echo "[$(date +'%T')] === $1" >> ${PQUERY_REACH_COPIED_LOG}
    fi
  fi
}

# Trap ctrl-c
trap ctrl-c SIGINT

ctrl-c(){
  echoit "CTRL+C Was pressed. Attempting to terminate running processes..."
  KILL_PIDS=`ps -ef | grep "$RANDOMR" | grep -v "grep" | awk '{print $2}' | tr '\n' ' '`
  if [ "${KILL_PIDS}" != "" ]; then
    echoit "Terminating the following PID's: ${KILL_PIDS}"
    kill -9 ${KILL_PIDS} >/dev/null 2>&1
  fi
  echoit "Done. Terminating pquery-run.sh with exit code 2..."
  exit 2
}

# Make sure directories set in vars are there
if [ ! -d "${BASEDIR}" ]; then echo "Assert! Basedir ($BASEDIR) does not exist or is not a directory!"; exit 1; fi
if [ ! -d "${WORKDIR}" ]; then echo "Assert! Workdir ($WORKDIR) does not exist or is not a directory!"; exit 1; fi
if [ ! -d "${COPYDIR}" ]; then echo "Assert! Copydir ($COPYDIR) does not exist or is not a directory!"; exit 1; fi

# Make sure we've got all items we need
if [ ! -r "${SCRIPT_PWD}/reducer.sh" ];            then echo "Assert! reducer.sh not found!"; exit 1; fi
if [ ! -r "${SCRIPT_PWD}/pquery-run.sh" ];         then echo "Assert! pquery-run.sh not found!"; exit 1; fi
if [ ! -r "${SCRIPT_PWD}/pquery-prep-red.sh" ];    then echo "Assert! pquery-prep-red.sh not found!"; exit 1; fi
if [ ! -r "${SCRIPT_PWD}/pquery-clean-known.sh" ]; then echo "Assert! pquery-clean-known.sh not found!"; exit 1; fi
if [ $(ls ${SCRIPT_PWD}/pquery/*.sql 2>/dev/null | wc -l) -lt 1 ]; then echo "Assert! No SQL input files found!" exit 1; fi

pquery_run(){
  cd ${SCRIPT_PWD}
  if [ ! -r $STATIC_PQUERY_BIN -o "${STATIC_PQUERY_BIN}" == "" ]; then
    # Select a random pquery binary
    PQUERY_BIN="$(ls ${SCRIPT_PWD}/pquery/pquery* | grep -vE "\.cfg|\.sql|\.oldv1|-pxc" | shuf --random-source=/dev/urandom | head -n1)"
    echoit "Randomly selected pquery binary: ${PQUERY_BIN}"
  else
    PQUERY_BIN=${STATIC_PQUERY_BIN}
    echoit "Static configured pquery binary: ${PQUERY_BIN}"
  fi

  # Select a random SQL file
  #Removed the tar.xz input file as it is usually present as main-ms-ps-md.sql in any case, and untarring in $SESSION threads = lots of I/O
  #INFILE="$(ls ${SCRIPT_PWD}/pquery/*.sql ${SCRIPT_PWD}/pquery/main*.tar.xz | shuf --random-source=/dev/urandom | head -n1)"
  INFILE="$(ls ${SCRIPT_PWD}/pquery/*.sql | shuf --random-source=/dev/urandom | head -n1)"
  echoit "Randomly selected SQL input file: ${INFILE}"

  # Select a random mysqld options file
  # Using a random mysqld options file was found not to work well as many trials would get reduced but they were just a "bad option". Instead we should have a "Very common" subset of mysqld options and use that one (TODO). In the pquery-run.conf sed's below, this was also remarked so it can be unmarked once such a common set of options file is created, and this section can change to just use that file instead of randomly selecting one.
  #OPTIONS_INFILE="$(ls ${SCRIPT_PWD}/pquery/mysqld_options_*.txt | shuf --random-source=/dev/urandom | head -n1)"
  #echoit "Randomly selected mysqld options input file: ${INFILE}"

  # Select a random duration from 10 seconds to 3 minutes
  PQUERY_RUN_TIMEOUT=$[$RANDOM % 170 + 10];
  echoit "Randomly selected trial duration: ${PQUERY_RUN_TIMEOUT} seconds"

  # pquery-run.sh setup and run
  echoit "Setting up new pquery-run.sh configuration file at ${PQUERY_CONF}..."
  cat ${SCRIPT_PWD}/pquery-run.sh |
   sed "s|^INIT_OPT=\"|INIT_OPT=\"${MYINIT} |" | \
   sed "s|\${SCRIPT_PWD}/generator|${SCRIPT_PWD}/generator|g" | \
   sed "s|\${SCRIPT_PWD}/text_string.sh|${SCRIPT_PWD}/text_string.sh|g" | \
   sed "s|\${SCRIPT_PWD}/valgrind_string.sh|${SCRIPT_PWD}/valgrind_string.sh|g" | \
   sed "s|\${SCRIPT_PWD}/vault_test_setup.sh|${SCRIPT_PWD}/vault_test_setup.sh|g" | \
   sed "s|\${SCRIPT_PWD}/ldd_files.sh|${SCRIPT_PWD}/ldd_files.sh|g" | \
   sed "s|\${SCRIPT_PWD}/sysbench|${SCRIPT_PWD}/sysbench|g" > ${PQUERY_RUN}
  sed -i "4 iSKIPCHECKDIRS=1" ${PQUERY_RUN}  # TODO: check if there is a better way then skipping some safety checks in pquery-run.sh
  cat ${SCRIPT_PWD}/pquery-run.conf |
   sed "s|^[ \t]*PQUERY_BIN=.*|PQUERY_BIN=${PQUERY_BIN}|" | \
   sed "s|^[ \t]*INFILE=.*|INFILE=${INFILE}|" | \
   #sed "s|^[ \t]*INFILE=.*|INFILE=~/percona-qa/pquery/main.sql|" | \
   sed "s|^[ \t]*OPTIONS_INFILE=.*|OPTIONS_INFILE=${OPTIONS_INFILE}|" | \
   sed "s|^[ \t]*ADD_RANDOM_OPTIONS=.*|ADD_RANDOM_OPTIONS=0|" | \
   #sed "s|^[ \t]*ADD_RANDOM_OPTIONS=.*|ADD_RANDOM_OPTIONS=1|" | \
   sed "s|^[ \t]*MAX_NR_OF_RND_OPTS_TO_ADD=.*|MAX_NR_OF_RND_OPTS_TO_ADD=0|" | \
   #sed "s|^[ \t]*MAX_NR_OF_RND_OPTS_TO_ADD=.*|MAX_NR_OF_RND_OPTS_TO_ADD=2|" | \
   sed "s|^[ \t]*ADD_RANDOM_TOKUDB_OPTIONS=.*|ADD_RANDOM_TOKUDB_OPTIONS=0|" | \
   sed "s|^MYEXTRA=|MYEXTRA=\"${MYEXTRA}\"|" | \
   sed "s|^[ \t]*RANDOMD=.*|RANDOMD=${RANDOMD}|" | \
   sed "s|^[ \t]*WORKDIR=.*|WORKDIR=${PQR_WORKDIR}|" | \
   sed "s|^[ \t]*BASEDIR=.*|BASEDIR=${BASEDIR}|" | \
   sed "s|^[ \t]*RUNDIR=.*|RUNDIR=${PQR_RUNDIR}|" | \
   sed "s|^[ \t]*SCRIPT_PWD=.*|SCRIPT_PWD=${SCRIPT_PWD}|" | \
   sed "s|^[ \t]*PXC=.*|PXC=0|" | \
   sed "s|^[ \t]*ARCHIVE_INFILE_COPY=.*|ARCHIVE_INFILE_COPY=0|" | \
   sed "s|^[ \t]*DOCKER=.*|DOCKER=0|" | \
   sed "s|^[ \t]*TRIALS=.*|TRIALS=1|" | \
   sed "s|^[ \t]*VALGRIND_RUN=.*|VALGRIND_RUN=0|" | \
   sed "s|^[ \t]*SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY=.*|SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY=1|" | \
   sed "s|^[ \t]*SAVE_SQL=.*|SAVE_SQL=0|" | \
   sed "s|^[ \t]*MYSQLD_START_TIMEOUT.*|MYSQLD_START_TIMEOUT=60|" | \
   sed "s|^[ \t]*MULTI_THREADED_RUN=.*|MULTI_THREADED_RUN=$(if [ ${THREADS} -gt 1 ]; then echo '1'; else echo '0'; fi)|" | \
   sed "s|^[ \t]*QUERIES_PER_THREAD=.*|QUERIES_PER_THREAD=2147483647|" | \
   sed "s|^[ \t]*PQUERY_RUN_TIMEOUT=.*|PQUERY_RUN_TIMEOUT=${PQUERY_RUN_TIMEOUT}|" | \
   sed "s|^[ \t]*THREADS=.*|THREADS=${THREADS}|" | \
   sed "s|^[ \t]*MULTI_THREADED_TESTC_LINES=.*|MULTI_THREADED_TESTC_LINES=20000|" > ${PQUERY_CONF}
  chmod +x ${PQUERY_RUN}
  echoit "Done. Now starting: ${PQUERY_RUN}..."
  echoit "=================================================================================================================="
  ${PQUERY_RUN} ${PQUERY_CONF_FILE} | tee -a ${PQUERY_REACH_LOG}
  echoit "=================================================================================================================="
}

cleanup(){
  rm -Rf ${PQR_WORKDIR}; rm -Rf ${PQR_RUNDIR}; rm -Rf ${PQUERY_RUN}; rm -f ${PQUERY_CONF}
}

# Go!
ORIGINAL_WORKDIR=${WORKDIR}
export WORKDIR=${WORKDIR}/${RANDOMR}  # Update workdir to include a random dir nr
# pquery-run.sh variables setup
PQUERY_RUN=${WORKDIR}/${RANDOMD}_pquery-run.sh
PQUERY_CONF_FILE=${RANDOMD}_pquery-run.conf
PQUERY_CONF=${WORKDIR}/${PQUERY_CONF_FILE}
PQR_WORKDIR=${WORKDIR}/${RANDOMD}
PQR_RUNDIR=${WORKDIR}/${RANDOMD}_RUN
if [ -d ${WORKDIR} ]; then WORKDIR=; echo "Assert! ${WORKDIR} already exists. A random number collision?? Try and restart the script"; exit 1; fi
mkdir ${WORKDIR}
PQUERY_REACH_LOG=${WORKDIR}/${RANDOMD}_pquery-reach.log
PQUERY_REACH_COPIED_LOG=${COPYDIR}/${RANDOMR}/${RANDOMD}_pquery-reach.log  # Used only at end after workdir is removed (to write final output), i.e. when RUN_DONE is set to 1
touch ${PQUERY_REACH_LOG}
echoit "pquery-reach.sh (PID $$) main working directory: ${WORKDIR} | Logfile: ${PQUERY_REACH_LOG}"
echoit "pquery-run.sh working directory: ${PQR_WORKDIR} | pquery-run run directory: ${PQR_RUNDIR}"
echoit "Base directory: ${BASEDIR} | Copy directory: ${COPYDIR} | Work directory: ${WORKDIR}"
echoit "MYINIT: ${MYINIT}"
echoit "MYEXTRA: ${MYEXTRA}"

# Main Loop
while true; do
  # Run pquery_run.sh with a randomly generated configuration
  pquery_run
  # Analyze the single trial executed by pquery_run.sh
  if [ -d ${PQR_WORKDIR}/1 ]; then
    echoit "Found bug at ${PQR_WORKDIR}/1, preparing reducer for it using pquery-prep-red.sh..."
    cd ${PQR_WORKDIR}
    ${SCRIPT_PWD}/pquery-prep-red.sh reach | sed "s|^|[$(date +'%T')] === |" | tee -a ${PQUERY_REACH_LOG}
    sleep 1 && sync
    echoit "Filtering known bugs using pquery-clean-known.sh (1st attempt)..."
    ${SCRIPT_PWD}/pquery-clean-known.sh reach | sed "s|^|[$(date +'%T')] === |" | tee -a ${PQUERY_REACH_LOG}
    # The repeat of pquery-clean-known.sh is a hack workaround. There is a bug somewhere which causes pquery-clean-known.sh to do;
    # [14:19:11] === Filtering known bugs using pquery-clean-known.sh...
    # [14:20:46] === New, and specific (MODE=3) bug found! Reducing the same...
    # Note the very long run time (1m35s) which should be a few seconds at max + the fact that it does not find a bug already present
    # This currently seems to happen only for this string; 'm_form->s->row_type == m_create_info->row_type' and perhaps a few others
    # Another one it happens for (perhaps it is related to having a '=' in the filter string?) is 'old_dd_tab .= __null'
    # When executed manually on a directory later, 'pquery-clean-known.sh reach' works perfectly fine. This is a complex bug
    # Already checked that the path is correct, and also noted that other bugs earlier in the log get cleaned up just fine.
    sleep 1 && sync
    echoit "Filtering known bugs using pquery-clean-known.sh (2nd attempt)..."
    ${SCRIPT_PWD}/pquery-clean-known.sh reach | sed "s|^|[$(date +'%T')] === |" | tee -a ${PQUERY_REACH_LOG}
    if [ -d ${PQR_WORKDIR}/1 ]; then
      if [ -r ${PQR_WORKDIR}/reducer1.sh ]; then
        if grep -qi "^MODE=3" ${PQR_WORKDIR}/reducer1.sh; then
          echoit "New, and specific (MODE=3) bug found! Reducing the same..."
          # Update pquery-reach++.sh found counter (which is reset to 0 on each run of pquery-reach++.sh), if used
          if [ -r /tmp/pqr_status.cnt ]; then
            CURRENT_COUNT=$(cat /tmp/pqr_status.cnt)
            CURRENT_COUNT=$[ $CURRENT_COUNT + 1 ]
            echo "$CURRENT_COUNT" > /tmp/pqr_status.cnt
          fi
          sed -i "s|^[ \t]*INIT_OPT=\"|INIT_OPT=\"${MYINIT} |" ${PQR_WORKDIR}/reducer1.sh  # Semi-hack to get things like "--early-plugin-load=keyring_file.so --keyring_file_data=keyring --innodb_sys_tablespace_encrypt=ON" in [MY]MID/INIT_OPT to work
          # Approximately matching pquery-go-expert.sh settings, with some improvements
          sed -i "s|^FORCE_SKIPV=0|FORCE_SKIPV=1|" ${PQR_WORKDIR}/reducer1.sh  # Setting this means the script will not terminate in some cases; it's a weigh off between STAGE1_LINES (13 set below) being reached in most cases (in which case this script WILL terminate and finish as it will go through the other STAGEs in reducer) or it not being reached (>13 lines left in the testcase in MULTI reduction mode), in which case the script indeed will not terminate as it will stay in MULTI reducion mode.
          sed -i "s|^MULTI_THREADS=[0-9]\+|MULTI_THREADS=3 |" ${PQR_WORKDIR}/reducer1.sh
          sed -i "s|^MULTI_THREADS_INCREASE=[0-9]\+|MULTI_THREADS_INCREASE=3|" ${PQR_WORKDIR}/reducer1.sh
          sed -i "s|^MULTI_THREADS_MAX=[0-9]\+|MULTI_THREADS_MAX=9 |" ${PQR_WORKDIR}/reducer1.sh
          sed -i "s|^STAGE1_LINES=[0-9]\+|STAGE1_LINES=13|" ${PQR_WORKDIR}/reducer1.sh
          # Early copy time
          if [ ${EARLYCOPY} -eq 1 ]; then
            echoit "Preliminary copy of the work directory (${WORKDIR}) to the copy directory (${COPYDIR}) for safety..."
            cp -r ${WORKDIR} ${COPYDIR} 
          fi
          echoit "=================================================================================================================="
          ${PQR_WORKDIR}/reducer1.sh | tee -a ${PQUERY_REACH_LOG}
          REDUCER_EXIT_STATUS=${PIPESTATUS[0]}  # With thanks, https://unix.stackexchange.com/a/14276/241016
          echoit "=================================================================================================================="
          # Figure out the reducer workdir, which is stored in the pquery reach log by searching for a reducer-specific text output
          REDUCER_WORKDIR=$(grep '\[Init\] Workdir' ${PQUERY_REACH_LOG} | sed "s|.*:[ \t]*||")  # "[Init] Workdir" is from reducer
          # Fix reducer so it points now to the COPYDIR instead of the WORKDIR, just before the copy
          # This makes it easier to re-run reducer1.sh directly from the COPYDIR after WORKDIR has been deleted automatically
          sed -i "s|^INPUTFILE=\"${ORIGINAL_WORKDIR}|INPUTFILE=\"${COPYDIR}|" ${PQR_WORKDIR}/reducer1.sh
          # Copy time
          if [ ${EARLYCOPY} -eq 1 ]; then
            echoit "Re-copying the work directory (${WORKDIR}) to the copy directory (${COPYDIR}) in ovewrite mode..."
          else
            echoit "Copying the work directory (${WORKDIR}) to the copy directory (${COPYDIR})..."
          fi
          COPY_RESULT=0
          cp -rf ${WORKDIR} ${COPYDIR} 
          if [ $? -eq 0 ]; then
            COPY_RESULT=1
            echoit "Removing work directory (${WORKDIR})..."
            rm -Rf ${WORKDIR}
            RUN_DONE=1
          else
            echoit "Found some issues while copying the work directory to the copy directory. Not deleting work directory for safety..."
          fi
          if [ ${REDUCER_EXIT_STATUS} -eq 0 ]; then
            if [ ${COPY_RESULT} -eq 1 ]; then
              if [ -r "${COPYDIR}/${RANDOMR}/${RANDOMD}/1/default.node.tld_thread-0.sql_out" ]; then
                echoit "Copy complete. Testcase location: $(echo "${COPYDIR}/${RANDOMR}/${RANDOMD}/1/default.node.tld_thread-0.sql_out")"
              else
                if [ -r "${COPYDIR}/${RANDOMR}/${RANDOMD}/1/startup_failure_thread-0.sql_out" ]; then
                  echoit "Copy complete. Testcase location: $(echo "${COPYDIR}/${RANDOMR}/${RANDOMD}/1/startup_failure_thread-0.sql_out")"
                else
                  echoit "Copy complete. Review ${COPYDIR}/${RANDOMR}/${RANDOMD}/1 for testcase location (assert: this should not really have happened; the testcase was not found?)"
                fi
              fi
              rm -Rf ${REDUCER_WORKDIR}  # Cleanup reducer workdir
              echoit "pquery-reach.sh complete, new bug found and reduced! Exiting normally..."
              exit 0
            else
              echoit "pquery-reach.sh complete, new bug found and reduced! Howerver, the copy of the work dir (${WORKDIR}) to the copy dir (${COPYDIR}) failed. Thus, not deleting the workdir nor the reducer directory (${REDUCER_WORKDIR}). Exiting with status 1..."
              exit 1
            fi
            exit 3  # Defensive coding only, exit as 0 or 1 should happen just above
          else
            echoit "As reducer (${PQR_WORKDIR}/reducer1.sh) exit status was non-0 (${REDUCER_EXIT_STATUS}), the reducer workdir was not deleted. Please manually delete ${REDUCER_WORKDIR} when outcome analysis or re-reduction has been completed..."
            if [ ${COPY_RESULT} -eq 1 ]; then
              echoit "pquery-reach.sh complete, new bug found and reducer attempted (but was not successful). Exiting with status 1..."
            else
              echoit "pquery-reach.sh complete, new bug found and reduced! Howerver, the copy of the work dir (${WORKDIR}) to the copy dir (${COPYDIR}) failed. Thus, not deleting the workdir nor the reducer directory (${REDUCER_WORKDIR}). Exiting with status 1..."
            fi
            exit 1
          fi
          exit 3  # Defensive coding only, exit as 0 or 1 should happen just above
        else
          if [ -r ${PQR_WORKDIR}/1/log/master.err ]; then
            if grep -qi "nknown variable" ${PQR_WORKDIR}/1/log/master.err; then
              echoit "This run had an invalid/unknown mysqld variable (dud), cleaning up & trying again..."
              cleanup
              continue
            else
              if [ `ls ${PQR_WORKDIR}/1/data/*core* 2>/dev/null | wc -l` -lt 1 ]; then
                echoit "No error log found, and no core found. Likely some SQL was executed like 'RELEASE' or 'SHUTDOWN', cleaning up & trying again..."
                cleanup
                continue
              else
                echoit "No error log AND no core found. Odd... (out of space perhaps?) TODO"
                exit 1
              fi
            fi
          else
            echoit "New, and non-specific (MODE=4) bug found! Terminating for manual analysis..."
            echoit "Use: $ cd ${WORKDIR}; vi reducer1.sh   # To get started!"
            exit 0
          fi
        fi
      fi
    else
      echoit "This bug was filtered (already logged), cleaning up & trying again..."
      cleanup
      continue
    fi
  else
    echoit "No bug found, cleaning up & trying again..."
    cleanup
    continue
  fi
done

