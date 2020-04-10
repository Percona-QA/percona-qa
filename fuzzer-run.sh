#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Internal variables - do not modify
SCRIPT_PWD=$(cd `dirname $0` && pwd)

# User variables
BASEDIR=/sda/PS280218-percona-server-5.7.19-17-linux-x86_64-debug  # Warning: running this script will remove ALL data directories in BASEDIR
FUZZERS=113  # Number of sub fuzzers (the total number of fuzzers is one higher as there is a master fuzzer also)

# Auto-created variables (can be changed if needed)
AFL_BIN=${SCRIPT_PWD}/fuzzer/afl-2.52b/afl-fuzz
DICTIONARY=${SCRIPT_PWD}/mysql-dictionary.fuzz
BASE_BIN="$(echo "${BASEDIR}/bin/mysql_embedded")"  # Only use the embedded server, or a setup where client+server are integrated into one binary, compiled/instrumented with afl-gcc or afl-g++ (instrumentation wrappers for gcc/g++)

# Code hack required in mysqld_main() in sql/mysqld.cc (i.e. in the source code tree before compiling with AFL);
# Insert under the line "my_progname= argv[0];" in mysqld_main function in sql/mysqld.cc;
#  /* With thanks, https://stackoverflow.com/a/308712/1208218 */
#  char cmdex[80];
#  strcpy(cmdex, "sh -c 'b=$(echo \"");
#  strcat(cmdex, my_progname);
#  strcat(cmdex, "\" | sed \"s|.*/||\"); rm -Rf $b; cp -a data $b'");
#  system(cmdex);
# This will copy the directory 'data' (which is made as a template below) to mysqld0, mysqld1, etc. WHEN the mysqld binary is
# renamed to mysqld0 before runnig it, etc. If the mysql_embedded binary is used it will be mysql_embedded 0 etc.

# Code hack required in main() in client/mysql.cc (i.e. the source code tree before compiling with AFL);
# Insert under the lines "int main(int argc,char *argv[])" and "{";
#   /* With thanks, https://stackoverflow.com/a/308712/1208218 */
#  char cmdex[80];
#  strcpy(cmdex, "sh -c 'b=$(echo \"");
#  strcat(cmdex, argv[0]);
#  strcat(cmdex, "\" | sed \"s|.*/||\"); rm -Rf $b; cp -a data $b'");
#  system(cmdex);
# This is for mysql_embedded

# System variables, do not change
BINARY="$(echo "${BASE_BIN}" | sed 's|.*/||')"

exit_help(){
  echo "This script expects one startup option: M or S (Master or Slaves) as the first option."
  echo "Also remember to set BASEDIR etc. variables inside the script."
  echo "Note that it is recommended to run M (Master) in a seperate terminal from S (Slaves), allowing better output analysis."
  echo "Warning: running this script will remove ALL data directories in BASEDIR!"
  echo "Terminating."; exit 1
}
# Setup
if [ ! -r ${BASE_BIN} ]; then
  echo "${BASE_BIN} not present! Please compile a server with the embedded server included"
  echo "Terminating."; exit 1
fi
if [ "${1}" == "" ]; then
  exit_help
elif [ "${1}" != "M" -a "${1}" != "S" ]; then
  exit_help
elif [ "${1}" == "M" ]; then
  cd /sys/devices/system/cpu
  sudo echo performance | sudo tee cpu*/cpufreq/scaling_governor
fi
cd ${BASEDIR}  # Extremely important, do not change
if [ "${PWD}" != "${BASEDIR}" ]; then
  echo 'Safety assert: $PWD!=$BASEDIR, please check your BASEDIR path. Tip; avoid double and traling slashe(s).'
  echo "${PWD}!=${BASEDIR}"
fi
if [ ! -d in ]; then
  echo "Please create your in directory with a starting testcase, for example ./in/start.sql"
  echo "Terminating."; exit 1
fi
INPUT_DIR_OPTION="in"
if [ ! -d out ]; then
  mkdir out
elif [ "${1}" == "M" ]; then
  echo "(!) Found existing 'out' directory - please ensure that this is what you want; reusing data from a previous run."
  echo "If this is not what you want, please CTRL+C now and delete, rename or move the 'out' directory. Sleeping 13 seconds."
  INPUT_DIR_OPTION="-"
  sleep 13
elif [ "${1}" == "S" ]; then
  # Use existing out dir, not in dir. This works whetter this is a brand new run with a just-created (by M[aster] thread) 'out' dir
  # or whetter this is a previously-long-running resumed run where the 'out' dir has already been there from before
  ### TODO - this needs work - you can de-remark the next line for continuning an existing run with out/fuzer{nr} in place
  ###        but it does not work correctly when starting a new run ([-] PROGRAM ABORT : Resume attempted but old output directory
  ###        not found) as the out/fuzzer{nr} directories do not exist at that point yet.
  ### INPUT_DIR_OPTION="-"
  sleep 0.01  # dummy, remove when above is fixed
fi
if [ "${1}" == "M" ]; then
  killall afl-fuzz 2>/dev/null
  rm -Rf data  # data_TEMPLATE
  ${SCRIPT_PWD}/startup.sh
  ./all_no_cl
  #mv ./data ./data_TEMPLATE # Now handled inside mysqld by hack of mysqld_main (ref notes above)
fi

# For environment variables see:
# https://github.com/rc0r/afl-fuzz/blob/master/docs/env_variables.txt
# https://groups.google.com/forum/#!searchin/afl-users/AFL_NO_ARITH%7Csort:date/afl-users/1LKXY6u6QDk/KRXna2sPBAAJ

# A good way to check if something is working (which is not clear from the AFL GUI console), is to check
# grep "command_line" ./out/fuzzer0/fuzzer_stats  # Or replace '0' in this line with another active fuzzer number
# And then (after hacking the command_line to make it just the mysql_embedded{nr} + options call only) execute it manually to verify operation

# TERMINAL 1 (master)
if [ "${1}" == "M" ]; then
  #rm -Rf ./data0
  #cp -a ./data_TEMPLATE ./mysqld0 # Now handled inside mysqld by hack of mysqld_main (ref notes above)
  cp -f ${BASE_BIN} ${BASE_BIN}0
  echo "Starting master with id fuzzer0 (mysqld0)..."
  rm -f ${BASEDIR}/${BINARY}${FUZZER}/general${FUZZER}  # General log file (useful for debugging)
  # When http://bugs.mysql.com/bug.php?id=81782 is fixed, re-add --binary-mode to the command below. Also note that due to http://bugs.mysql.com/bug.php?id=81784, the --force option has to be after the --execute option
  # Note that with a M[aster]/[S]lave setup, no need for -d is required as in a master/slave setup the master is automatically deterministic and the slaves automatically use -d (non-deterministic)
  # Note that one cannot use --execute="USE test;SOURCE ..." so instead the test db is referenced on the end of the CLI call line
  AFL_NO_AFFINITY=1 AFL_SHUFFLE_QUEUE=1 AFL_NO_ARITH=1 AFL_FAST_CAL=1 AFL_NO_CPU_RED=1 ${AFL_BIN} -M fuzzer0 -m 5000 -t 60000 -i ${INPUT_DIR_OPTION} -o out -x ${DICTIONARY} ${BASE_BIN}0 --server-arg="\"--basedir=${BASEDIR}\"" --server-arg="\"--tmpdir=${BASEDIR}/${BINARY}0\"" --server-arg="\"--datadir=${BASEDIR}/${BINARY}0\"" --server-arg="\"--core-file\"" --server-arg="\"--log-output=FILE\"" --server-arg="\"--general_log\"" --server-arg="\"--general_log_file=general0\"" -A -B -r --execute="\"SOURCE @@\"" --force test &
fi

# TERMINAL 2 (after master is up) (subfuzzers)
if [ "${1}" == "S" ]; then
  for FUZZER in $(seq 1 ${FUZZERS}); do
    #rm -Rf ./data${FUZZER}
    #cp -a ./data_TEMPLATE ./mysqld${FUZZER} # Now handled inside mysqld by hack of mysqld_main (ref notes above)
    cp -f ${BASE_BIN} ${BASE_BIN}${FUZZER}
    echo "Starting slave with id fuzzer${FUZZER} (mysqld${FUZZER})..."
    rm -f ${BASEDIR}/${BINARY}${FUZZER}/general${FUZZER}  # General log file (useful for debugging)
    # When http://bugs.mysql.com/bug.php?id=81782 is fixed, re-add --binary-mode to the command below. Also note that due to http://bugs.mysql.com/bug.php?id=81784, the --force option has to be after the --execute option
    # Note that with a M[aster]/[S]lave setup, no need for -d is required as in a master/slave setup the master is automatically deterministic and the slaves automatically use -d (non-deterministic)
    # Note that one cannot use --execute="USE test;SOURCE ..." so instead the test db is referenced on the end of the CLI call line
    sleep 1; AFL_NO_AFFINITY=1 AFL_SHUFFLE_QUEUE=1 AFL_NO_ARITH=1 AFL_FAST_CAL=1 AFL_NO_CPU_RED=1 ${AFL_BIN} -S fuzzer${FUZZER} -m 5000 -t 60000 -i ${INPUT_DIR_OPTION} -o out -x ${DICTIONARY} ${BASE_BIN}${FUZZER} --server-arg="\"--basedir=${BASEDIR}\"" --server-arg="\"--tmpdir=${BASEDIR}/${BINARY}${FUZZER}\"" --server-arg="\"--datadir=${BASEDIR}/${BINARY}${FUZZER}\"" --server-arg="\"--core-file\"" --server-arg="\"--log-output=FILE\"" --server-arg="\"--general_log\"" --server-arg="\"--general_log_file=${BASEDIR}/${BINARY}${FUZZER}/general${FUZZER}\"" -A -B -r --execute="\"SOURCE @@\"" --force test &
  done
  # Cleanup screen in background (can be done manually as well, all processes are in background
  while :; do
    sleep 2
    clear
  done
fi

