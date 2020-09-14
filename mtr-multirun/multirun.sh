#!/bin/bash
# set -x

#  Copyright (c) 2019-2020, MariaDB Corporation Ab.
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; version 2 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA */

# Developed by Matthias Leich, MariaDB 

# FIXME:
# - Extend to using getopt and maybe some config file
# - two modes:
#   - simple (default):
#     Basically the current code (no additional files polluting the test dir).
#   - extended:
#     Take the original test and generate some extended one by sourcing script snippets preferably
#     at test begin and end. That kind of extended test requires "polluting" the test dir with
#     additional files.

NPROC=`nproc`

HDD="/media/user/myhdd"

echo
echo "MULTIRUN.sh Version 2.0"
echo

function usage () {
   echo "Usage: MULTIRUN.sh <test_script> <type> <list of mtr options>"
   echo "       <test_script> : Top level test script like suite/mariabackup/huge_lsn.test  OR  suite/innodb/t/innodb-index.test"
   echo "                       Other forms of assignment are not supported."
   echo "       Supported types :"
   echo "       cpu    -- generate extreme CPU load + MTR uses '--parallel=$NPROC --mem'"
   echo "       hdd    -- generate extreme IO load  + MTR uses '--parallel=$NPROC --vardir=<value set in script. Please edit that>"
   echo "                 Using an SSD would neither meet the goal of the test nor be good for the SSD lifetime"
   echo "       all    -- generate extreme CPU and IO load + + MTR uses '--parallel=$NPROC --vardir=<value set in script. Please edit that>"
   echo "       Assigning a list of MTR options is optional."
   echo "       Please"
   echo "       - do not enclose that list in quotes because MTR will treat this as one single option."
   echo "       - be aware that the current script will append '--vardir="$VARDIR" --mysqld=--innodb_use_native_aio=0'"
   echo "         to the RQG call in order to dictate options needed for proper working."
   echo
   echo "Example 1 (in source build):"
   echo "cd <source tree>/mysql-test"
   echo "MULTIRUN.sh suite/innodb_fts/t/fulltext2.test cpu --mysqld=--innodb_stats_persistent=1 --mysqld=ft_min_word_len=3"
   echo
   echo "Example 2 (build in sub directory of source line <source tree>/bld_debug):"
   echo "cd <source tree>/bld_debug/mysql-test"
   echo "MULTIRUN.sh ../../mysql-test/main/1st.test cpu"
   echo
   echo "Inside of the script is a setting"
   echo "HDD=/media/user/myhdd because this is how Ubuntu mounts my external HDD."
   echo "Please replace that setting with something fitting to your testing box in case using 'hdd' or 'all'."
}

if [ $# -lt 2 ]
then
   echo "In minimum two input values are required."
   usage
   exit 4
else
   echo "Values picked from command line"
   TEST_SCRIPT="$1"
   echo "TEST_SCRIPT:       ->$TEST_SCRIPT<-"
   shift
   TYPE="$1"
   echo "TYPE:              ->$TYPE<-"
   shift
   echo "Remaining options: ->$*<-"
fi

if [ ! -f "$TEST_SCRIPT" ]
then
   echo "ERROR: The assigned TEST_SCRIPT ->$TEST_SCRIPT<- does not exist or is not a plain file."
   exit 4
fi
echo $TEST_SCRIPT | egrep '\.test$' 2>&1 > /dev/null
RC=$?
if [ $RC -ne 0 ]
then
   echo "ERROR: The assigned TEST_SCRIPT ->$TEST_SCRIPT<- does not end with '.test'"
   exit 4
fi


if [ \( "$TYPE" != "cpu" \) -a \( "$TYPE" != "hdd" \) -a \( "$TYPE" != "all" \) ]
then
   echo "The second input value is neither 'cpu' nor 'hdd' nor 'all'."
   usage
   exit 4
fi

if [ \( "$TYPE" = "hdd" \) -o \( "$TYPE" = "all" \) ]
then
   # HDD must point to a usable directory
   if [ ! -d "$HDD" ]
   then
      echo "Please edit the current script so that it points to a directory within a HDD based filesystem."
      echo "In the moment HDD ('$HDD') points to some directory which does not exist."
      usage
      exit 4
   fi
fi

TEST_BASE=`echo "$TEST_SCRIPT" | sed -e 's/\.test$//g'`
echo "->$TEST_BASE<-"
TEST_NAME=`basename "$TEST_BASE"`
echo "->$TEST_NAME<-"
TEST_SCRIPT_PREFIX=`dirname "$TEST_SCRIPT"`
echo "->$TEST_SCRIPT_PREFIX<-"
# Cut a maybe existing
# - trailing '/t'
# - prepended '<whatever>/mysql-test'
# away.
TEST_SUITE=`echo "$TEST_SCRIPT_PREFIX" | sed -e 's|\/t$||g' -e 's|^.*mysql-test||g'`
echo "->$TEST_SUITE<-"
TEST_SUITE=`basename "$TEST_SUITE"`
echo "->$TEST_SUITE<-"
if [ "$TEST_SUITE" == "" ]
then
   TEST_SUITE="main"
fi
# Add the slash. We need it all time.
TEST_SCRIPT_PREFIX="$TEST_SCRIPT_PREFIX""/"
# 't/' --> 'r/'
TEST_RESULT_PREFIX=`echo "$TEST_SCRIPT_PREFIX" | sed -e 's/t\/$/r\//g'`

TEST_RESULT="$TEST_RESULT_PREFIX""$TEST_NAME"".result"
if [ ! -f "$TEST_RESULT" ]
then
   # FIXME: Figure out the consequences
   echo "INTERNAL ERROR: Result file computed to ->$TEST_RESULT<- not found."
   # exit 8
fi
TEST_OPT="$TEST_SCRIPT_PREFIX""$TEST_NAME"".opt"
if [ ! -f "$TEST_OPT" ]
then
   TEST_OPT=""
fi
TEST_M_OPT="$TEST_SCRIPT_PREFIX""$TEST_NAME""-master.opt"
if [ ! -f "$TEST_M_OPT" ]
then
   TEST_M_OPT=""
fi
TEST_S_OPT="$TEST_SCRIPT_PREFIX""$TEST_NAME""-slave.opt"
if [ ! -f "$TEST_S_OPT" ]
then
   TEST_S_OPT=""
fi

if [ "$LOAD_GENERATOR" == "" ]
then
   LOAD_GENERATOR=$NPROC
fi
if [ "$TEST_CLONES" == "" ]
then
   TEST_CLONES=$NPROC
fi
if [ "$REPETITIONS" == "" ]
then
   REPETITIONS=30
fi

MTR_APPEND="--parallel=$TEST_CLONES --suite=$TEST_SUITE --repeat=$REPETITIONS"

# The goal
# --------
# In case of going with non modified testscript get PARALLEL MTR Worker.
# Every of these workers should execute our test.
#
# Known MTR property
# ------------------
# ./mysql-test-run.pl --parallel=8 --repeat=10 innodb.innodb-lock
# There are 2 variants ('xtradb' and 'innodb_plugin') defined to run that test.
# MTR will start exact 2 MTR Worker instead of 8 which leads to
# - no significant bad impact on overall load because the load generators run anyway and make
#   sufficient load
# - sub optimal use of the hardware because less test runs means less coverage by (brute force) use.
# Old solution non nice:
# Generate 8 clones of the test (files with different name like Clone_1.test etc. but same content).
# ./mysql-test-run.pl --parallel=8 --repeat=10 --do-test=Clone_
# But we "pollute" the test directory.
#
# Great hint from Marko:
# ./mysql-test-run.pl --parallel=8 --repeat=10 <n times innodb.innodb-lock>
# In case n is sufficient big than we have 8 MTR worker which means optimal use of the
# hardware resources provided.
#

NUM=1
while [ $NUM -le $TEST_CLONES ]
do
   MTR_APPEND="$MTR_APPEND $TEST_NAME"
   NUM=$(($NUM + 1))
done

# MTR_APPEND="--parallel=$TEST_CLONES --suite=$TEST_SUITE --do-test=Clone_ --repeat=$REPETITIONS"
# echo $MTR_APPEND
# exit
echo "TEST_SCRIPT    assigned+checked  ->$TEST_SCRIPT<-"
echo "TEST_RESULT    computed+checked  ->$TEST_RESULT<-"
echo "TEST_OPT       computed+checked  ->$TEST_OPT<- empty == There is no opt file."
echo "TEST_M_OPT     computed+checked  ->$TEST_M_OPT<- empty == There is no master opt file."
echo "TEST_S_OPT     computed+checked  ->$TEST_S_OPT<- empty == There is no slave opt file."
echo "TEST_NAME      computed          ->$TEST_NAME<-"
echo "TEST_SUITE     computed          ->$TEST_SUITE<-"
echo "Processors     reported by OS    ->$NPROC<-"
echo "LOAD_GENERATOR assigned|computed : $LOAD_GENERATOR"
echo "TEST_CLONES    assigned|computed : $TEST_CLONES"
echo "REPETITIONS    assigned|computed : $REPETITIONS"
echo
echo "assigned          == Taken from command line."
echo "assigned|computed == Assigned at begin of script otherwise default computed."
echo
echo "In case the MTR call fails"
echo "- but not immediate at begin because of bad options/suite or test names"
echo "- but in minimum one of the MTR workers harvested a [ pass ]"
echo "please think twice before assuming that the current script has a defect."
echo
echo "$0"
echo "1. Just runs MTR based tests with some LEGAL setup which is similar what usual"
echo "   build+test mechanics do."
echo "2. Starts $LOAD_GENERATOR load generators which do"
echo "   - NOT use mysqltest or run SQL somehow"
echo "   - NOT create, drop or modify files used by MariaDB servers or mysqltest etc."

if [ 0 -eq 1 ]
then
echo "1. Maybe generates $TEST_CLONES CLONES (make copy with different name) of '$TEST_SCRIPT'."
echo "   And the clones are just files with same content but different name."
echo "   And '$TEST_SCRIPT' itself (its content!) MUST already pass runs through MTR."
fi

echo "Typical mistakes in MTR tests which check-testcases is frequent unable to detect"
echo "- imperfect cleanup regarding files created at allowed locations around test end"
echo "  - sometimes caught by --repeat=<a value > 1> but only if the test itself is capable to"
echo "    suffer from a file it will create."
echo "  - otherwise causing sporadic fails of successing OTHER tests fiddling with a file having"
echo "    the same name at the same location."
echo "- place files at disallowed (shared with other concurrent MTR workers) locations"
echo "  This is valid even if the test creates a files and deletes it microseconds later."
echo "  - EVIL: \$MYSQL_TEST_DIR or /tmp or ... because it is not MTR worker specific."
echo "          W2 overwrites the file of W1 and than W1 reads that file ..."
echo "  - SAVE: \$MYSQLTEST_VARDIR because it is MTR worker specific."
echo "- forgotten disconnects or disconnect but forgotten to wait until gone"
echo "  The next test sees an connection in the processlist which belongs to"
echo "  - the predecessing test executed by the same MTR Worker"                    
echo "  - a connection created by himself"
echo "  - a finished call of some tool like   mysql mysqldump mysqlbackup ..."
echo "  but is not prepared to handle that."
echo

# No use as long as tests do not get automatic extended like add code around begin and end of test.
# And even than only one derivate test is required.
if [ 0 -eq 1 ]
then
   # set -x
   num=$TEST_CLONES
   rm -f "$TEST_SCRIPT_PREFIX""/Clone_"*
   rm -f "$TEST_RESULT_PREFIX""/Clone_"*
   rm -f stop
   while [ $num -gt 0 ]
   do
      CLONE_NAME="Clone_""$num"
      SCRIPT_CLONE="$TEST_SCRIPT_PREFIX""$CLONE_NAME"".test"
      # echo "SCRIPT_CLONE ->$SCRIPT_CLONE<-"
      RESULT_CLONE="$TEST_RESULT_PREFIX""$CLONE_NAME"".result"
      # echo "RESULT_CLONE ->$RESULT_CLONE<-"
      OPT_CLONE="$TEST_SCRIPT_PREFIX""$CLONE_NAME"".opt"
      OPT_M_CLONE="$TEST_SCRIPT_PREFIX""$CLONE_NAME""-master.opt"
      OPT_S_CLONE="$TEST_SCRIPT_PREFIX""$CLONE_NAME""-slave.opt"
      cp "$TEST_SCRIPT" "$SCRIPT_CLONE"
      cp "$TEST_RESULT" "$RESULT_CLONE"
      if [ "$TEST_OPT" != "" ]
      then
         cp "$TEST_OPT" "$OPT_CLONE"
      fi
      if [ "$TEST_M_OPT" != "" ]
      then
         cp "$TEST_M_OPT" "$OPT_M_CLONE"
   
      fi
      if [ "$TEST_S_OPT" != "" ]
      then
         cp "$TEST_S_OPT" "$OPT_S_CLONE"
      fi
      num=$(($num - 1))
   done
fi


# Poll till
#    >= $NPROC mysqld servers were once running -> go on
# or
#    MAX_WAITS was exceeded -> exit
# Purpose
# -------
# Getting the tests started and especially the servers up costs significant resources (cpu/io).
# So don't increase the time required by the load generators making load.
#
function wait_till_server_up () {
   NO_OF_LINES=0
   MAX_WAITS=60
   CURR_WAITS=0
   while [ \( $CURR_WAITS -lt $MAX_WAITS \) -a \( ! -f stop \) ]
   do
      NO_OF_LINES=`grep 'mysqld: ready for connections' "$VARDIR"/*/log/mysqld.1.err 2>/dev/null | wc -l`
      if [ $NO_OF_LINES -ge $NPROC ]
      then
         break
      fi
      sleep 0.5;
      CURR_WAITS=$(($CURR_WAITS + 1))
   done
   if [ $CURR_WAITS -ge $MAX_WAITS ]
   then
      m1="Load Generator: Give up. 30s waited but never >= $NPROC entries 'ready for connections'"
      m2="in mysqld.1.err(s) observed."
      echo "$m1 $m2" >> stop
      exit 4
   fi
}

function make_load_cpu () {
   wait_till_server_up
   while [ ! -f stop ]
   do
      lnum=1000
      while [ $lnum -gt 0 ]
      do
         lnum=$(($lnum - 1))
      done
   done
}

function make_load_hdd () {
   FAT_FILE="$HDD""/fat_file""$1"
   wait_till_server_up
   while [ ! -f stop ]
   do
      rm -f "$FAT_FILE"
      dd if=/dev/zero of="$FAT_FILE" bs=1M count=500 2>/dev/null
      sync
   done
   rm -f "$FAT_FILE"
}

function kill_server {
   PID_FILE=$1
   if [ -f $PID_FILE ]
   then 
      SERVER_PID=`cat "$PID_FILE"`
      if [ "" = "$SERVER_PID" ]
      then
         echo "No server pid for killing found in '$PID_FILE'." >> stop
      else
         echo "Initiate kill of server with pid $SERVER_PID." >> stop
         kill -9 $SERVER_PID
      fi
   else
      echo "The PID_FILE '$PID_FILE' never existed at all or does no more exist." >> stop
   fi
}

# Poll till
#    >= $NPROC mysqld servers were once running -> go on
# or
#    MAX_WAITS was exceeded -> exit
# Purpose
# -------
# Generating backtraces costs significant resources (cpu/io).
# So don't increase the time required by the load generators making load.
# They are no more required anyway.
#
# FIXME:
# Waiting for $NPROC servers is not reliable if the test is extreme short.
function stop_load_for_debugger () {
   wait_till_server_up
   while [ ! -f stop ]
   do
      NO_OF_FAIL_LINES=`egrep " w[1-9][0-9]*  *\[ .*fail \]" multirun.prt | wc -l`
      if [ $NO_OF_FAIL_LINES -gt 0 ]
      then
         echo "$NO_OF_FAIL_LINES MTR test runs failed" >> stop
         FAIL_WORKER=`egrep " w[1-9][0-9]*  *\[ .*fail \]" multirun.prt | head -1 | sed -e 's/^.* w\([[1-9][0-9]*\) \[ .*fail \]/\1/g'`
         echo "Number of the MTR Worker with failing test picked ->$FAIL_WORKER<-." >> stop
         date >> stop
         num=1
         while [ $num -le $NPROC ]
         do
            if [ $num -ne $FAIL_WORKER ]
            then
               # Example: /dev/shm/vardir/8/run/mysqld.1.pid
               PID_FILE="$VARDIR""/""$num""/run/mysqld.1.pid"
               kill_server "$PID_FILE"
               # We might run standard replication.
               PID_FILE="$VARDIR""/""$num""/run/mysqld.2.pid"
               kill_server "$PID_FILE"
            fi
            num=$(($num + 1))
         done
         ps -C mysqld >> stop
         date >> stop
      else
         sleep 0.2
      fi
   done
}

trap 'trap_int_quit' SIGINT SIGQUIT

trap_int_quit()
{
   echo "MULTIRUN.sh trapped a SIGINT (Ctrl-C) or a SIGQUIT (Ctrl-\)."
   echo "Trying to stop the child processes ..."
   echo "SIGINT or SIGQUIT received. Trying to stop the child processes." >> stop
   wait
}

pwd

echo "TYPE ->$TYPE<-"

if [ $TYPE == 'cpu' ]
then
   num=$NPROC
   VARDIR="/dev/shm/vardir"
   rm -rf "$VARDIR"
   stop_load_for_debugger &
   echo "Starting $num CPU load generators into the background."
   while [ $num -gt 0 ]
   do
      make_load_cpu &
      num=$(($num - 1))
   done
elif [ $TYPE == 'hdd' ]
then
   VARDIR="$HDD""/vardir"
   rm -rf "$VARDIR"
   stop_load_for_debugger &
   echo "Starting two HDD IO load generator into the background."
   make_load_hdd 1 &
   make_load_hdd 2 &
elif [ $TYPE == 'all' ]
then
   num=$NPROC
   VARDIR="$HDD""/vardir"
   rm -rf "$VARDIR"
   stop_load_for_debugger &
   echo "Starting $num CPU load and two HDD IO load generators into the background."
   while [ $num -gt 0 ]
   do
      make_load_cpu &
      num=$(($num - 1))
   done
   make_load_hdd 1 &
   make_load_hdd 2 &
else 
   echo "ERROR: Type '$TYPE' is not supported."
   exit 4
fi

date
echo "Starting the execution of $NPROC clones of '$TEST_NAME' with 30 repetitions."
#  --mysqld=--innodb_use_native_aio=0              \
nice -19 ./mysql-test-run.pl $* --vardir="$VARDIR" \
   --testcase-timeout=30 --suite-timeout=300 $MTR_APPEND | tee multirun.prt
echo "Signal the CPU load generators to stop." >> multirun.prt
echo "$0 : Signal the CPU load generators to stop." >> stop
wait
