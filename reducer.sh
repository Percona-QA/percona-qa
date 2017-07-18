#!/bin/bash

# Copyright (c) 2012,2013 Oracle and/or its affiliates. All rights reserved.
# Use is subject to license terms.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301
# USA

# In active development: 2012-2017

# ======== Dev Contacts
# Main developer: Roel Van de Paar <roel A.T vandepaar D.O.T com>
# With contributions from & thanks to: Andrew Dalgleish, Ramesh Sivaraman, Tomislav Plavcic
# With thanks to the team at Oracle for open sourcing the original internal version

# ======== User configurable variables section (see 'User configurable variable reference' below for more detail)
# === Basic options
INPUTFILE=                      # The SQL file to be reduced. This can also be given as the first option to reducer.sh. Do not use double quotes
MODE=4                          # Required. Most often used modes: 4=Any crash (TEXT not required), 3=Search for a specific TEXT in mysqld error log, 2=Idem, but in client log
TEXT="somebug"                  # The text string you want reducer to search for, in specific locations depending on the MODE selected. Regex capable. Use with MODEs=1,2,3,5,6,7,8
WORKDIR_LOCATION=1              # 0: use /tmp (disk bound) | 1: use tmpfs (default) | 2: use ramfs (needs setup) | 3: use storage at WORKDIR_M3_DIRECTORY
WORKDIR_M3_DIRECTORY="/ssd"     # Only relevant if WORKDIR_LOCATION is set to 3, use a specific directory/mount point
MYEXTRA="--no-defaults --log-output=none --sql_mode=ONLY_FULL_GROUP_BY"  # mysqld options to be used (and reduced). Note: TokuDB plugin loading is checked/done automatically
BASEDIR="/sda/percona-server-5.7.10-1rc1-linux-x86_64-debug"             # Path to the MySQL BASE directory to be used
DISABLE_TOKUDB_AUTOLOAD=0       # On/Off (1/0) Prevents mysqld startup issues when using standard MySQL server (i.e. no TokuDB available) with a testcase containing TokuDB SQL
SCRIPT_PWD=$(cd `dirname $0` && pwd) # script location to access storage engine plugin sql file. 

# === Sporadic testcases        # Used when testcases prove to be sporadic *and* fail to reduce using basic methods
FORCE_SKIPV=0                   # On/Off (1/0) Forces verify stage to be skipped (auto-enables FORCE_SPORADIC)
FORCE_SPORADIC=0                # On/Off (1/0) Forces issue to be treated as sporadic

# === True Multi-Threaded       # True multi-threaded testcase reduction (only program in the world that does this) based on random replay (auto-covers sporadic testcases)
PQUERY_MULTI=0                  # On/off (1/0) Enables true multi-threaded testcase reduction based on random replay (auto-enables PQUERY_MOD)

# === Reduce startup issues     # Reduces startup issues. This will only work if a clean start (mysqld --no-defaults) works correctly; otherwise template creation will fail also
REDUCE_STARTUP_ISSUES=0         # Default/normal use: 0. Set to 1 to reduce mysqld startup issues (without SQL simplication), caused for example by a failing --option to mysqld

# === Reduce GLIBC/SS crashes   # Remember that if you use REDUCE_GLIBC_OR_SS_CRASHES=1 with MODE=3, then the console/typescript log is searched for TEXT, not the mysqld error log
REDUCE_GLIBC_OR_SS_CRASHES=0    # Default/normal use: 0. Set to 1 to reduce testcase based on a GLIBC crash or stack smash being detected. MODE=3 (TEXT) and MODE=4 (all) supported
SCRIPT_LOC=/usr/bin/script      # The script binary (sudo yum install util-linux) is required for reducing GLIBC crashes

# === Hang issues               # For catching hang issues (both in normal runtime as well as during shutdown). Must set MODE=0 for this option to become active
TIMEOUT_CHECK=600               # When MODE=0 is used, this specifies the nr of seconds to be used as a timeout. Do not set too small (eg. >600 sec). See examples in help below.

# === Timeout mysqld            # Uncommonly used option. Used to terminate (timeout) mysqld after x seconds, while still checking for MODE=2/3 TEXT. See examples in help below.
TIMEOUT_COMMAND=""              # A specific command, executed as a prefix to mysqld. For example, TIMEOUT_COMMAND="timeout --signal=SIGKILL 10m"

# === Advanced options          # Note: SLOW_DOWN_CHUNK_SCALING is of beta quality. It works, but it may affect chunk scaling somewhat negatively in some cases
SLOW_DOWN_CHUNK_SCALING=0       # On/off (1/0) If enabled, reducer will slow down it's internal chunk size scaling (also see SLOW_DOWN_CHUNK_SCALING_NR)
SLOW_DOWN_CHUNK_SCALING_NR=3    # Slow down chunk size scaling (both for chunk reductions and increases) by not modifying the chunk for this number of trials. Default=3
USE_TEXT_STRING=0               # On/off (1/0) If enabled, when using MODE=3, this uses text_string.sh (percona-qa) instead of searching the entire error log. No effect otherwise
TEXT_STRING_LOC=~/percona-qa/text_string.sh  # text_string.sh binary in percona-qa. To get this script use:  cd ~; git clone https://github.com/Percona-QA/percona-qa.git

# === Expert options
MULTI_THREADS=10                # Do not change (default=10), unless you fully understand the change (x mysqld servers + 1 mysql or pquery client each)
MULTI_THREADS_INCREASE=5        # Do not change (default=5),  unless you fully understand the change (increase of above, both for std and PQUERY_MULTI)
MULTI_THREADS_MAX=50            # Do not change (default=50), unless you fully understand the change (maximum number of MULTI threads, both for std and PQUERY_MULTI)
PQUERY_EXTRA_OPTIONS=""         # Do not change (default=""), unless you fully understand the change (adds extra options to pquery replay, used for QC trials)
PQUERY_MULTI_THREADS=3          # Do not change (default=3),  unless you fully understand the change (x mysqld servers + 1 pquery client with x threads)
PQUERY_MULTI_CLIENT_THREADS=30  # Do not change (default=30), unless you fully understand the change (x [client] threads mentioned above)
PQUERY_MULTI_QUERIES=400000     # Do not change (default=400000), unless you fully understand the change (queries to be executed per client per trial)
PQUERY_REVERSE_NOSHUFFLE_OPT=0  # Do not change (default=0), unless you fully understand the change (reverses --no-shuffle into shuffle and vice versa)
                                # On/Off (1/0) (Default=0: --no-shuffle is used for standard pquery replay, shuffle is used for PQUERY_MULTI. =1 reverses this)

# === pquery options            # Note: only relevant if pquery is used for testcase replay, ref PQUERY_MOD and PQUERY_MULTI
PQUERY_MOD=0                    # On/Off (1/0) Enable to use pquery instead of the mysql CLI. pquery binary (as set in PQUERY_LOC) must be available
PQUERY_LOC=~/percona-qa/pquery/pquery  # The pquery binary in percona-qa. To get this binary use:  cd ~; git clone https://github.com/Percona-QA/percona-qa.git

# === Other options             # The options are not often changed
CLI_MODE=0                      # When using the CLI; 0: sent SQL using a pipe, 1: sent SQL using --execute="SOURCE ..." command, 2: sent SQL using redirection (mysql < input.sql)
ENABLE_QUERYTIMEOUT=0           # On/Off (1/0) Enable the Query Timeout function (which also enables and uses the MySQL event scheduler)
QUERYTIMEOUT=90                 # Query timeout in sec. Note: queries terminated by the query timeout did not fully replay, and thus overall issue reproducibility may be affected
LOAD_TIMEZONE_DATA=0            # On/Off (1/0) Enable loading Timezone data into the database (mainly applicable for RQG runs) (turned off by default=0 since 26.05.2016)
STAGE1_LINES=90                 # Proceed to stage 2 when the testcase is less then x lines (auto-reduced when FORCE_SPORADIC or FORCE_SKIPV are active)
SKIPSTAGEBELOW=0                # Usually not changed (default=0), skips stages below and including requested stage
SKIPSTAGEABOVE=10               # Usually not changed (default=10), skips stages above and including requested stage
FORCE_KILL=0                    # On/Off (1/0) Enable to forcefully kill mysqld instead of using mysqladmin shutdown etc. Auto-disabled for MODE=0.

# === Percona XtraDB Cluster
PXC_MOD=0                       # On/Off (1/0) Enable to reduce testcases using a Percona XtraDB Cluster. Auto-enables PQUERY_MODE=1
PXC_ISSUE_NODE=0                # The node on which the issue would/should show (0,1,2 or 3) (default=0 = check all nodes to see if issue occured)
WSREP_PROVIDER_OPTIONS=""       # wsrep_provider_options to be used (and reduced).

# === MySQL Group Replication
GRP_RPL_MOD=0                   # On/Off (1/0) Enable to reduce testcases using MySQL Group Replication. Auto-enables PQUERY_MODE=1
GRP_RPL_ISSUE_NODE=0            # The node on which the issue would/should show (0,1,2 or 3) (default=0 = check all nodes to see if issue occured)

# === MODE=5 Settings           # Only applicable when MODE5 is used
MODE5_COUNTTEXT=1               # Number of times the text should appear (default=minimum=1). Currently only used for MODE=5
MODE5_ADDITIONAL_TEXT=""        # An additional string to look for in the CLI output when using MODE 5. When not using this set to "" (=default)
MODE5_ADDITIONAL_COUNTTEXT=1    # Number of times the additional text should appear (default=minimum=1). Only used for MODE=5 and where MODE5_ADDITIONAL_TEXT is not ""

# === Old ThreadSync options    # No longer commonly used
TS_TRXS_SETS=0
TS_DBG_CLI_OUTPUT=0
TS_DS_TIMEOUT=10
TS_VARIABILITY_SLEEP=1

# ======== Machine configurable variables section: DO NOT REMOVE THIS
#VARMOD# < please do not remove this, it is here as a marker for other scripts (including reducer itself) to auto-insert settings

# ==== MySQL command line (CLI) output TEXT search examples
#TEXT=                       "\|      0 \|      7 \|"  # Example of how to set TEXT for MySQL CLI output (for MODE=2 or 5)
#TEXT=                       "\| i      \|"            # Idem, text instead of number (text is left-aligned, numbers are right-aligned in the MySQL CLI output)

# ======== User configurable variable reference
# - INPUTFILE: the SQL trace to be reduced by reducer.sh. This can also be given as the fisrt option to reducer.sh (i.e. $ ./reducer.sh {inputfile.sql})
# - MODE: 
#   - MODE=0: Timeout testing (server hangs, shutdown issues, excessive command duration etc.) (set TIMEOUT_CHECK)
#   - MODE=1: Valgrind output testing (set TEXT)
#   - MODE=2: mysql CLI (Command Line Interface, i.e. the mysql client)/pquery client output testing (set TEXT) 
#   - MODE=3: mysqld error output log or console/typescript log (when REDUCE_GLIBC_OR_SS_CRASHES=1) testing (set TEXT)
#   - MODE=4: Crash or GLIBC crash (when REDUCE_GLIBC_OR_SS_CRASHES=1) testing
#   - MODE=5 [BETA]: MTR testcase reduction (set TEXT) (Can also be used for multi-occurence CLI output testing - see MODE5_COUNTTEXT)
#   - MODE=6 [ALPHA]: Multi threaded (ThreadSync) Valgrind output testing (set TEXT)
#   - MODE=7 [ALPHA]: Multi threaded (ThreadSync) mysql CLI/pquery client output testing (set TEXT)
#   - MODE=8 [ALPHA]: Multi threaded (ThreadSync) mysqld error output log testing (set TEXT)
#   - MODE=9 [ALPHA]: Multi threaded (ThreadSync) crash testing
# - SKIPSTAGEBELOW: Stages up to and including this one are skipped (default=0).
# - SKIPSTAGEABOVE: Stages above and including this one are skipped (default=9).
# - TEXT: Text to look for in MODEs 1,2,3,5,6,7,8. Ignored in MODEs 4 and 9. 
#   Can contain extended grep (i.e. grep -E or egrep)+regex syntax like "^ERROR|some_other_string". Remember this is regex: specify | as \| etc. 
#   For MODE5, you would use a mysql CLI to get the desired output "string" (see example given above) and then set MODE5_COUNTTEXT
# - PQUERY_MOD: 1: use pquery, 0: use mysql CLI. Causes reducer.sh to use pquery instead of the mysql client for replays (default=0). Supported for MODE=1,3,4
# - PQUERY_LOC: Location of the pquery binary (retrieve pquery like this; $ cd ~; bzr branch lp:percona-qa; # then ref ~/percona-qa/pquery/pquery[-ms])
# - PQUERY_EXTRA_OPTIONS: Extra options to pquery which will be added to the pquery command line. This is used for query correctness trials
# - PXC_MOD: 1: bring up 3 node Percona XtraDB Cluster instead of default server, 0: use default non-cluster server (mysqld)
# - GRP_RPL_MOD: 1: bring up 3 node Group Replication instead of default server, 0: use default non-cluster server (mysqld)
#   see lp:/percona-qa/pxc-pquery/new/pxc-pquery_info.txt and lp:/percona-qa/docker_info.txt for more information on this. See above for some limitations etc.
#   IMPORTANT NOTE: If this is set to 1, ftm, these settings (and limitations) are automatically set: INHERENT: PQUERY_MOD=1, LIMTATIONS: FORCE_SPORADIC=0, 
#   SPORADIC=0, FORCE_SKIPV=0, SKIPV=1, MYEXTRA="", MULTI_THREADS=0 
# - PXC_ISSUE_NODE: This indicates which node you would like to be checked for presence of the issue. 0 = Any node. Valid options: 0, 1, 2, or 3. Only works
#   for MODE=4 currently.
# - GRP_RPL_ISSUE_NODE: This indicates which node you would like to be checked for presence of the issue. 0 = Any node. Valid options: 0, 1, 2, or 3. Only works
#   for MODE=4 currently.
# - PXC_DOCKER_COMPOSE_LOC: Location of the Docker Compose file used to bring up 3 node Percona XtraDB Cluster (using images previously prepared by "new" method) 
# - QUERYTIMEOUT: Number of seconds to wait before terminating a query (similar to RQG's querytimeout option). Do not set < 40 to avoid initial DDL failure
#   Warning: do not set this smaller then 1.5x what was used in RQG. If set smaller, the bug may not reproduce. 1.5x instead of 1x is a simple precaution
# - TS_TRXS_SETS [ALPHA]: For ThreadSync simplification (MODE 6+), use the last x set of thread actions only
#   (i.e. the likely crashing statements are likely at the end only) (default=1, 0=disable) 
#   Increase to increase reproducibility, but increasing this exponentially also slightly lowers reliability. (DEBUG_SYNC vs session sync issues)
# - TS_DBG_CLI_OUTPUT: ONLY activate for debugging. We need top speed for the mysql CLI to reproduce multi-threaded issues accurately
#   This turns on -vvv debug output for the mysql client (Best left disabled=default=0)
#   Turning this on *will* significantly reduce (if not completely nullify) issue reproducibility due to excessive disk logging
# - TS_DS_TIMEOUT: Number of seconds to wait in a DEBUG_SYNC lock situation before terminating current DEBUG_SYNC lock holds
# - TS_VARIABILITY_SLEEP: Number of seconds to wait before a new transaction set is processed (may slightly increase/decrease issue reproducibility) 
#   Suggested values: 0 (=default) or 1. This is one of the first parameters to test (change from 0 to 1) if a ThreadSync issue is not reproducible
# - WORKDIR_LOCATION: Select which medium to use to store the working directory (Note that some issues require the extra speed of setting 1,2 or 3 to reproduce)
#   (Note that the working directory is also copied to /tmp/ after the reducer run finishes if tmpfs or ramfs are used)
#   - WORKDIR_LOCATION=0: use /tmp/ (disk bound)
#   - WORKDIR_LOCATION=1: use tmpfs (default)
#   - WORKDIR_LOCATION=2: use ramfs (setup: sudo mkdir -p /mnt/ram; sudo mount -t ramfs -o size=4g ramfs /mnt/ram; sudo chmod -R 777 /mnt/ram;)
#   - WORKDIR_LOCATION=3: use a specific storage device (like an ssd or other [fast] storage device), mounted as WORKDIR_M3_DIRECTORY
# - WORKDIR_M3_DIRECTORY: If WORKDIR_LOCATION is set to 3, then this directory is used
# - STAGE1_LINES: When the testcase becomes smaller than this number of lines, proceed to STAGE2 (default=90)
#   Only change if reducer keeps trying to reduce by 1 line in STAGE1 for a long time (seen very rarely)
# - MYEXTRA: Extra options to pass to myqsld (for instance "--core" is handy in some cases, for instance with highly sporadic issues to capture a core)
#   (Btw, --core should generally be left disabled to obtain cleaner output ("core dumped" stdout messages, less space used, faster reducer runs)
#   - Also, --no-defaults as set in the default is removed automatically later on. It is just present here to highlight it's effectively (seperately) set.
# - BASEDIR: Full path to MySQL basedir (example: "/mysql/mysql-5.6"). 
#   If the directory name starts with '/mysql/' then this may be ommited (example: BASEDIR="mysql-5.6-trunk")
# - MULTI_THREADS: This option was an internal one only before. Set it to change the number of threads Reducer uses for the verify stage intially, and for 
#   reduction of sproradic issues if the verify stage found it is a sporadic issue. Recommended: 10, based on experience/testing/time-proven correctness.
#   Do not change unless you need to. Where this may come in handy, for a single occassion, is when an issue is hard to reproduce and very sporadic. In this
#   case you could activate FORCE_SKIPV (and thus automatically also FORCE_SPORADIC) which would skip the verify stage, and set this to a higher number for
#   example 20 or 30. This would then immediately boot into 20 or 30 threads trying to reduce the issue with subreducers (note: thus 20 or 30x mysqld...)
#   A setting less then 10 is really not recommended as a start since sporadic issues regularly only crash a few threads in 10 or 20 run threads.
# - MULTI_THREADS_INCREASE: this option configures how many threads are added to MULTI_THREADS if the original MULTI_THREADS setting did not prove to be
#   sufficient to trigger a (now declared highly-) sporadic issue. Recommended is setting 5 or 10. Note that reducer has a limit of MULTI_THREADS_MAX (50) 
#   threads (this literally means 50x mysqld + client thread(s)) as most systems (including high-end servers) start to seriously fail at this level (and 
#   earlier) Example; if you set MULTI_THREADS to 10 and MULTI_THREADS_INCREASE to 10, then the sequence (if no single reproduce can be established) will be:
#   10->20->30->40->50->Issue declared non-reproducible and program end. By this stage, the testcase has executed 6 verify levels *(10+20+30+40+50)=900 times.
#   Still, even in this case there are methods that can be employed to let the testcase reproduce. For further ideas what to do in these cases, see;
#   http://bazaar.launchpad.net/~percona-core/percona-qa/trunk/view/head:/reproducing_and_simplification.txt
# - FORCE_SPORADIC=0 or 1: If set to 1, STAGE1_LINES setting is ignored and set to 3. MULTI reducer mode is used after verify, even if issue is found to
#   seemingly not be sporadic (i.e. all verify threads, normally 10, reproduced the issue). This can be handy for issues which are very slow to reduce
#   or which, on visual inspection of the testcase reduction process are clearly sporadic (i.e. it comes to 2 line chunks with still thousands of lines 
#   in the testcase and/or there are many trials without the issue being observed. Another situation which would call for use of this parameter is when
#   produced testcases are still greater then 15 to 80 lines - this also indicates a possibly sporadic issue (even if verify stage manages to produce it 10x.
#   Note that this may be a bug in reducer too - i.e. a mismatch between verify stage and stage 1. Yet, if that were true, the issue would likely not 
#   reproduce to start with. Another plausible reason for this occurence (10/10 verified in verify stage but low frequency reproduction later on) is the
#   existence of 10 threads in verify stage vs 1 thread in stage 1. It has been observed that a very loaded server (or using Valgrind as it also slows the
#   code down significantly) is better at reproducing (many) issues then a low-load/single-thread-running machine. Whatever the case, this option will help.
# - FORCE_SKIV=0 or 1: If set to 1, FORCE_SPORADIC is automatically set to 1 also. This option skips the verify stage and goes straight into testcase reduction
#   mode. Ideal for issues that have a very low reproducibility, at least initially (usually either increases or decreases during a simplification run.)
#   Note that skipping the verify stage means that you may not be sure if the issue is reproducibile untill it actually reproduces (how long is a piece of 
#   string), and the other caveat is that the verify stage normally does some very important inital simplifications which is now skipped. It is suggested that 
#   if the issue becomes more reproducible during simplification, to restart reducer with this option turned off. This way you get the best of both worlds.
# - PQUERY_MULTI=0 or 1: If set to 1, FORCE_SKIV (and thus FORCE_SPORADIC) are automatically set to 1 also. This is true multi-threaded testcase reduction,
#   and it is based on random replay. Likely this will be slow, but effective. Alpha quality. This option removes the --no-shuffle option for pquery (i.e. 
#   random replay) and sets pquery options --threads=x (x=PQUERY_MULTI_CLIENT_THREADS) and --queries=5*testcase size. It also sets the number of subreducer
#   threads to PQUERY_MULTI_THREADS. To track success/status, view reducer output and/or check error logs;
#   $ grep -E "Assertion failure" /dev/shm/{reducer's epoch}/subreducer/*/error.log
#   Note that, idem to when you use FORCE_SKIV and/or FORCE_SPORADIC, STAGE1_LINES is set to 3. Thus, reducer will likely never completely "finish" (3 line
#   testases are somewhat rare), as it tries to continue to reduce the test to 3 lines. Just watch the output (reducer continually reports on remaining number
#   of lines and/or filesize) and decide when you are happy with the lenght of any reduced testcase. Suggested for developer convenience; 5-10 lines or less.
# - PQUERY_MULTI_THREADS: Think of this variable as "the initial setting for MULTI_THREADS" when PQUERY_MULTI mode is enabled; the initial number of subreducers
# - PQUERY_MULTI_CLIENT_THREADS: The number of client threads used for PQUERY_MULTI (see above) replays (i.e. --threads=x for pquery)
# - PQUERY_MULTI_QUERIES: The number of queries to execute for each and every trial before pquery ends (unless the server crashes/asserts). Must be
#   sufficiently high, given that the random replay which PQUERY_MULTI employs may not easily trigger an issue (and especially not if also sporadic)
# - PQUERY_REVERSE_NOSHUFFLE_OPT=0 or 1: If set to 1, PQUERY_MULTI runs will use --no-shuffle (the reverse of normal operation), and standard pquery (not multi-
#   threaded) will use shuffle (again the reverse of normal operation). This is a very handy option to increase testcase reproducibility. For example, when
#   reducing a non-multithreaded testcase (i.e. normally --no-shuffle would be in use), and reducer.sh gets 'stuck' at around 60 lines, setting this to 
#   on will start replaying the testcase randomly (shuffled). This may increase reproducibility. The final run scripts will have matching --no-shuffle or 
#   shuffle (i.e. no --no-shuffle present) set. Note that this may mean that a testcase has to be executed a few or more times given that if shuffle is
#   active (pquery's default, i.e. no --no-shuffle present), the testcase may replay differently then to what is needed. Powerful option, slightly confusing.
# - TIMEOUT_COMMAND: this can be used to set a timeout command for mysqld. It is prefixed to the mysqld startup. This is handy when encountering a shutdown
#   or server hang issue. When the timeout is reached, mysqld is terminated, but reduction otherwise happens as normal. Note that reducer will need some way
#   to establish that an actual problem was triggered. For example, suppose that a shutdown issue shows itself in the error log by starting to output INNODB
#   STATUS MONITOR output whenever the shutdown issue is occuring (i.e. server refuses to shutdown and INNODB STATUS MONITOR output keeps looping & end of
#   the SQL input file is apparently never reached). In this case, after a timeout of x minutes, thanks to the TIMEOUT_COMMAND, mysqld is terminated. After
#   the termination, reducer checks for "INNODB MONITOR OUTPUT" (MODE=3). It sees or not sees this output, and hereby it can continue to reduce the testcase
#   further. This would have been using MODE=3 (check error log output). Another method may be to interleave the SQL with a SHOW PROCESSLIST; and then
#   check the client output (MODE=2) for (for example) a runaway query. Different are issues where there is a 1) complete hang or 2) an issue that does not
#   or cannot!) represent itself in the error log/client log etc. In such cases, use TIMEOUT_CHECK and MODE=0. 
# - TIMEOUT_CHEK: used when MODE=0. Though there is no connection with TIMEOUT_COMMAND, the idea is similar; When MODE=0 is active, a timeout command prefix
#   for mysqld is auto-generated by reducer.sh. Note that MODE=0 does NOT check for specific TEXT string issues. It just checks if a timeout was reached
#   at the end of each trial run. Thus, if a server was hanging, or a statement ran for a very long time (if not terminated by the QUERYTIMEOUT setting), or
#   a shutdon was initiated but never completed etc. then reducer.sh will notice that the timeout was reached, and thus assume the issue reproduced. Always
#   set this setting at least to 2x the expected testcase run/duration lenght in seconds + 30 seconds extra. This longer duration is to prevent false 
#   positives. Reducer auto-sets this value as the timeout for mysqld, and checks if the termination of mysqld was within 30 seconds of this duration.
# - FORCE_KILL=0 or 1: If set to 1, then reducer.sh will forcefully terminate mysqld instead of using mysqladmin. This can be used when for example 
#   authentication issues prevent mysqladmin from shutting down the server cleanly. Normally it is recommended to leave this =0 as certain issues only
#   present themselves at the time of mysqld shutdown. However, in specific use cases it may be handy. Not often used. Auto-disabled for MODE=0.

# ======== Gotcha's
# - When reducing an SQL file using for example FORCE_SKIPV=1, FORCE_SPORADIC=1, PQUERY_MULTI=0, PQUERY_REVERSE_NOSHUFFLE_OPT=1, PQUERY_MOD=1, then reducer
#   will replay the SQL file, using pquery (PQUERY_MOD=1), using a single client (i.e. pquery) thread against mysqld (PQUERY_MULTI=0), in a sql shuffled order
#   (PQUERY_REVERSE_NOSHUFFLE_OPT=1) untill (FORCE_SKIPV=1 and FORCE_SPORADIC=1) it hits a bug. But notice that when the partially reduced file is written
#   as _out, it is normally not valid to re-start reducer using this _out file (for further reduction) using PQUERY_REVERSE_NOSHUFFLE_OPT=0. The reason is
#   that the sql replay order was random, but _out is generated based on the original testcase (sequential). Thus, the _out, when replayed sequentially,
#   may not re-hit the same issue. Especially when things are really sporadic this can mean having to wait long and be confused about the results. Thus,
#   if you start off with a random replay, finish with a random replay, and let the final bug testcase (auto-generated as {epoch}.*) be random replay too!

# ======== General develoment information
# - Subreducer(s): these are multi-threaded runs of reducer.sh started from within reducer.sh. They have a specific role, similar to the main reducer. 
#   At the moment there are only two such specific roles: verfication (reproducible yes/no + sporadic yes/no) and simplification (terminate a subreducer batch
#   (all of it) once a simpler testcase is found by one of the subthreads (subreducers), and use that testcase to again start new simplification subreducers.)
# - The files that are initially seen in the root working directory (i.e. $WORKD) are those generated by the step "[Init] Setting up standard working template", 
#   they are not an actual replay of any SQL file, at least not intitially; once the processing continues past this initial template creation, then the results
#   (i.e. the results of actual replays of SQL) will be in either;
#   - The subreducer directories $WORKD/subreducer/<nr>/ (ref above), provided reducer.sh is working in MULTI mode (even the standard VERIFY stage is [MULTI]) 
#   - Or, they will be in the same aforementioned directory $WORKD (and the output files from the initial template creation will now have been overwritten, 
#     though not the actual template), provided reducer.sh is working in single-threaded reduction mode (i.e. [MULTI] mode is not active).
# - Never use grep, always use egrep. See the next line why. Remember also that [0-9]\+ (a regex valid for grep) is written as [0-9]+ when using egrep/grep -E.
#   grep -E is the same as egrep. It is best to use grep -E because egrep will likely be deprecated from various OS'es at some point.
# - When using grep -E, ALWAYS use --binary-files=text to avoid issues with hex characters causing non-reproducibility and/or grep playing up. If you see
#   things like 'Binary file ... matches' as grep output it means you have executed grep against a file with binary chars, which is seen by the system as a
#   binary file (even though it may be a flat sql text file with a few hex characters in it). Adding the --binary-files=text will correctly process the file.

# ======== Ideas for improvement
# - The write of the file should be atomic - i.e. if reducer is interrupted during a testcase_out write, the file may be faulty. Check if this is so & fix
# - STAGE8 does currently know/consider whetter an issue is sporadic (alike to other STAGES, except STAGE 1). We could have an additional option like
#   STAGE8_FORCE_SPORADIC=0/1 Which would - specifically for STAGE 8 - try each option x times (STAGE8_SPORADIC_ATTEMPTS) when an issue is found to be (by the
#   auto-sporadic issue detection) or is forced to be (by STAGE8_FORCE_SPORADIC=1) sporadic. This allows easier reduction of mysqld options for sporadic issues)
# - A new mode could do this; main thread (single): run SQL, secondary thread (new functionality): check SHOW PROCESSLIST for certain regex TEXT regularly. This
#   would allow creating testcases for queries that have a long runtime. This new functionality likely will live outside process_outcome() as it is a live check
# - Incorporate 3+ different playback options: SOURCE ..., redirection with <, redirection with cat, (stretch goal; replay via MTR), etc. (there may be more)
#   THIS FUNCTIONALITY WAS ADDED 09-06-2016. "An expansion of this..." below is not implmeneted yet
#   - It has been clearly shown that different ways of replaying SQL may trigger a bug where other replay options do not. This looks to be more related to for 
#     example timing/server access method then to an inherent/underlying bug in for example the mysql client (CLI) workings. As such, the "resolution" is not 
#     to change ("fix") the client instead exploit this difference between replay options to trigger/reproduce bugs/replay test cases in multiple ways.
#   - An expansion of this could be where the initial stage (as it goes through it's iterations) replays each next iteration with a different replay method. 
#     This is not 100% covering however, as the last stage (with the least amount of changes to the SQL input file) would replay with replay method/option x, 
#     while x may not be the replay option which triggers the bug at hand. As such, a few more verify stage rounds (there's 6 atm - each with 10 replay threads)
#     may be needed to replay (partly "again", but this time with the least changed SQL file) the same SQL with each replay option. This would thus result in 
#     reducer needing a bit more time to do the VERIFY stage, but likely with good improved bug reproducibility. Untill this functionality is implemented, 
#     see the following file/page for reproducing & simplification ideas, which (if all followed diligently) usually result in bugs becoming reproducible;
#     http://bazaar.launchpad.net/~percona-core/percona-qa/trunk/view/head:/reproducing_and_simplification.txt
# - PXC Node work: rm -Rf's in other places (non-supported subreducers for example) will need sudo. Also test for sudo working correctly upfront
# - Add a MYEXRA simplificator at end (extra stage) so that mysqld options are minimal
# - Improve ";" work in STAGE4 (";" sometimes missing from results - does not affect reproducibility)
# - Improve VALGRIND/ERRORLOG run work (complete?)
# - Improve clause elimination when sub queries are used: "ORDER BY f1);" is not filtered due to the ending ")"
# - Keep 'success counters' over time of regex replacements so that reducer can eliminate those that are not effective 
#   Do this by proceduralizing the sed and then writing the regexes to a file with their success/failure rates
# - Include a note for Valgrind runs on a "universal" string - a string which would be found if there were any valgrind erros
#   Something like "[1-9]* ERRORS" or something 
# - Keep counters over time of which sed's have been successfull or not. If after many different runs, a sed remains 0 success, remove it
# - Proceduralize stages and re-run STAGE2 after the last stage as this is often beneficial for # of lines (and remove last [Info] line in [Finish])
# - Have to find some solution for the crash in tzinfo where reducer needs to use a non-Valgrind-instrumented build for tzinfo
# - (process) script could pass all RQG-set extra mysqld options into MYEXTRA or another variable to get non-reproducible issues to work
# - STAGE6: can be improved slightly furhter. See function for ideas.
#   Also, the removal of a column fails when a CREATE TABLE statement includes KEY(col), so maybe these keys can be pre-dropped or at the same time
#   Also, try and swap any use of the column to be removed to the name of column-1 (just store it in a variable) to avoid column missing error
#   And at the same time still promote removal of the said column 
# - start_mysqld_main() needs a bit more work to generate the $WORK_RUN file for MODE6+ as well (multiple $WORKO files are used in MODE6+)
#   Also remove the ifthen in finish() which test for MODE6+ for this and reports that implementation is not complete yet
# - STAGE6: 2 small bugs (ref output lines below): 1) Trying to eliminate a col that is not one & 2) `table0_myisam` instead of table0_myisam
#   Note that 2) may not actually be a bug; if the simplifacation of "'" failed for a sporadic testcase (as is the case here), it's hard to fix (check)
#   | 2013-08-19 10:35:04 [*] [Stage 6] [Trial 2] [Column 22/22] Trying to eliminate column '/*Indices*/' in table '`table0_myisam`'
#   | sed: -e expression #1, char 41: unknown command: `*'
# - Need another MODE which will look for *any* Valgrind issue based on the error count not being 0 (instead of named MODE1)
#   Make a note that this may cause issues to be missed: often, after simplification, less Valgrind errors are seen as the entire
#   SQL trace likely contained a number of issues, each originating from different Valgrind statements (can multi-issue be automated?)
# - Need another MODE which will attempt to crash the server using the crashing statement from the log, directly starting the vardir
#   left by RQG. If this works, dump the data, add crashing statement and load in a fresh instance and re-try. If this works, simplify.
# - "Previous good testcase backed up as $WORKO.prev" was only implemented for 1) parent seeing a new simplification subreducer testcase and
#   2) main single-threaded reducer seeing a new testcase. It still needs to be added to multi-threaded (ThreadSync) (i.e. MODE6+) simplification. (minor)
# - Multi-threaded simplification: thread-elimination > DATA + SQL threads simplified as if "one file" but accross files. 
#   Hence, all stages need to be updated to be multi-threaded/TS aware. Fair amount of work, but doable. 
#   See initial section of 'Verify' for some more information around multi_reducer_decide_input
# - Multi-threaded simplification: # threads left + non-sporadic: attempt all DATA+SQL1+SQLx combinations. Then normal simplify. 
#   Sporadic: normal simplify immediately.
# - Multi-threaded simplification of sporadic issues: could also start # subreducer sessions and have main reducer watch for _out creation.
#   Once found, abort all live subreducer threads and re-init with found _out file. Maybe a safety copy of original file should be used for running.
# - MODE9 work left
#   - When 2 threads are left (D+2T) then try MODE4 immediately instead of executing x TS_TE_ATTEMPTS attempts
#   - In single thread replay it should always do grep -E -v "DEBUG_SYNC" as DEBUG_SYNC does not make sense there (cosmetic, would be filtered anyway)
#   - bash$ echo -ne "test\r"; echo "te2" > use this implementation for same-line writing of threa fork commands etc
#   - TS_TRXS_SETS "greps" not fully corret yet: setting this to 10 lead to 2x main delay while it should have been 10. Works correctly when "1"
#   - TS_TRXS_SETS processing can be automated - and this is the simplification: test last, test last+1, test last+2, untill crash. (or chuncks?)
#   - Check if it is a debug server by issuing dummy DEBUG_SYNC command and see if it waits (TIMEOUT?)
#   - cut_threadsync_chunk is not in use at the moment, this will be used? but try ts_thread_elimination first
# - Need to capture interrupt (CTRL+C) signal and do some end-processing (show info + locations + copy to tmp if tmpfs/ramfs used)
# - If "sed: -e expression #1, char 44: unknown option to `s'" text or similar is seen in the output, it is likely due to the #VARMOD# block 
#   replacement in multi_reducer() failing somewhere. Update RV 16/9: Added functionality to fix/change ":" to "\:" ($FIXED_TEXT) to avoid this error.
# - Implement cmd line options instead of in-file options. Example:
#   while [ "$1" != ""]; do
#    case $1 in
#      -m | --mode     shift;MODE=$1;;   # shift to get actual file name into $1
#      -f | --file     shift;file=$1;;
#      *)              no_options;exit 1;;
#    esac
#    shift
#   done
# - Optimization: let 'Waiting for any forked subreducer threads to find a shorter file (Issue is sporadic: this will take time)' work for 30 minutes
#   or so, depending on file size. If no issue is found by then, restart or increase number of threads by 5.

# ======== Internal variable Reference
# $WORKD = Working directory (i.e. likely /tmp/<epoch>/ or /dev/shm/<epoch>)
# $INPUTFILE = The original input file (the file to reduce). This file, and this variable, are never changed.
# $WORKF = This is *originally* a copy of $INPUTFILE and hence the main input file in the working directory (i.e. $WORKD/in.sql). 
#   work   From it are made chunk deletes etc. and the result is stored in the $WORKT file
#   file   $WORKT overwrites $WORKF when a [for MODE4+9: "likely the same", for other MODES: "the same"] issue was located when executing $WORKT
# $WORKT = The "reduced" version of $WORKF, also in the working directory as $WORKD/in.tmp
#   temp   It may or may not cause the same issue like $WORKF can. This file is overwritten with a new "to be tested" version is being created
#   file   $WORKT overwrites $WORKO when a [for MODE4+9: "likely the same", for other MODES: "the same"] issue was located when executing $WORKT
# $WORKO = The "reduced" version of $WORKF, in the directory of the original input file as <name>_out
#   outf   This file definitely causes the same issue as $WORKO can, while being smaller
# $WORK_INIT, WORK_START, $WORK_STOP, $WORK_CL, $WORK_RUN, $WORK_RUN_PQUERY: Vars that point to various start/run scripts that get added to testcase working dir
# WORK_OUT: an eventual copy of $WORKO, made for the sole purpose of being used in combination with $WORK_RUN etc. This makes it handy to bundle them as all
#   of them use ${EPOCH} in the filename, so you get {some_epochnr}_start/_stop/_cl/_run/_run_pquery/.sql

# === Check TokuDB & RocksDB storage engine availability, and cleanup MYEXTRA to remove the related options
# SE Removal approach; 1) Engines are always loaded during stages 1-8 (using the TOKUDB and ROCKSDB variables, ref below) provided the matching .so file exists now
#                      2) Testcase reduction removal of engines (one-by-one) is tested in STAGE9
TOKUDB=
ROCKSDB=
if [ -r ${BASEDIR}/lib/mysql/plugin/ha_tokudb.so  ]; then TOKUDB="--plugin-load-add=tokudb=ha_tokudb.so --tokudb-check-jemalloc=0"; fi
MYEXTRA=$(echo ${MYEXTRA} | sed 's|--plugin-load-add=tokudb=ha_tokudb.so||g')
MYEXTRA=$(echo ${MYEXTRA} | sed 's|--plugin-load=tokudb=ha_tokudb.so||g')
MYEXTRA=$(echo ${MYEXTRA} | sed 's|--tokudb-check-jemalloc=0||g')
if [ -r ${BASEDIR}/lib/mysql/plugin/ha_rocksdb.so ]; then ROCKSDB="--plugin-load-add=rocksdb=ha_rocksdb.so"; fi
MYEXTRA=$(echo ${MYEXTRA} | sed 's|--plugin-load-add=rocksdb=ha_rocksdb.so||g')
MYEXTRA=$(echo ${MYEXTRA} | sed 's|--plugin-load=rocksdb=ha_rocksdb.so||g')

# For GLIBC crash reduction, we need to capture the output of the console from which reducer.sh is started. Currently only a SINGLE threaded solution using the 'scrip'
# binary from the util-linux package was found. The script binary is able to capture the GLIC output from the main console. It may be interesting to review the source C
# code for script, if available, to see how this is done. The following URL's may help with other possible solutions. However, LIBC_FATAL_STDERR_=1 has been found not to
# work at all. Perhaps this is due to mysqld being a setuid program (which is not confirmed). exec 2> and exec 1> redirections as well as process substitution i.e. >() have
# also been found not to work at all. Either the GLIBC trace will still be sent to the main console (and this may be the problem to start with), or it does not display at
# all when testing various interactions. To further complicate things, subshells $() and & may have interesting redirection dynamics. Many combinations were tried. Complex.
# * http://stackoverflow.com/questions/2821577/is-there-a-way-to-make-linux-cli-io-redirection-persistent
# * http://stackoverflow.com/questions/4616061/glibc-backtrace-cant-redirect-output-to-file
# * http://stackoverflow.com/questions/4290336/how-to-redirect-runtime-errors-to-stderr
# * https://sourceware.org/git/?p=glibc.git;a=patch;h=1327439fc6ef182c3ab8c69a55d3bee15b3c62a7
if [ $REDUCE_GLIBC_OR_SS_CRASHES -gt 0 ]; then
  if [ ! -r $SCRIPT_LOC ]; then
    echo "Error: REDUCE_GLIBC_OR_SS_CRASHES is activated, which requires the 'script' binary (part of the util-linux package), but this binary could not be found at $SCRIPT_LOC"
    echo "Please install it and/or set the correct path/binary name using the SCRIPT_LOC variable."
    echo "Terminating now."
    exit 1
  fi
  # Ensure the output of this console is logged. For this, reducer.sh is restarted with self-logging activated using script
  # With thanks, http://stackoverflow.com/a/26308092 from http://stackoverflow.com/questions/5985060/bash-script-using-script-command-from-a-bash-script-for-logging-a-session
  if [ -z "$REDUCER_TYPESCRIPT" ]; then
    TYPESCRIPT_UNIQUE_FILESUFFIX=$RANDOM
    exec $SCRIPT_LOC -q -f /tmp/reducer_typescript${TYPESCRIPT_UNIQUE_FILESUFFIX}.log -c "REDUCER_TYPESCRIPT=1 TYPESCRIPT_UNIQUE_FILESUFFIX=${TYPESCRIPT_UNIQUE_FILESUFFIX} $0 $@"
  fi
fi

# Sanitize input filenames which do not have a path specified by pointing to the current path. This ensures [Finish] output looks correct (ref $BUGTARDIR) 
if [[ "${INPUTFILE}" != *"/"* ]]; then INPUTFILE="./${INPUTFILE}"; fi;

echo_out(){
  echo "$(date +'%F %T') $1"
  if [ -r $WORKD/reducer.log ]; then echo "$(date +'%F %T') $1" >> $WORKD/reducer.log; fi
}

echo_out_overwrite(){
  # Used for frequent on-screen updating when using threads etc.
  echo -ne "$(date +'%F %T') $1\r"
}

ctrl_c(){
  echo_out "[Abort] CTRL+C Was pressed. Dumping variable stack"
  echo_out "[Abort] WORKD: $WORKD (reducer log @ $WORKD/reducer.log) | EPOCH: $EPOCH"
  if [ -s $WORKO ]; then  # If there were no issues found, $WORKO was never written
    echo_out "[Abort] Best testcase thus far: $WORKO"
  else
    echo_out "[Abort] Best testcase thus far: $INPUTFILE (= input file, no optimizations were successful)"
  fi
  echo_out "[Abort] End of dump stack"
  if [ $PXC_MOD -eq 1 ]; then
    echo_out "[Abort] Ensuring any remaining PXC nodes are terminated and removed"
    (ps -ef | grep -E 'node1_socket\|node2_socket\|node3_socket' | grep -E -v grep -E | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true)
    sleep 2; sync 
  fi
  if [ $GRP_RPL_MOD -eq 1 ]; then
    echo_out "[Abort] Ensuring any remaining Group Replication nodes are terminated and removed"
    (ps -ef | grep -E 'node1_socket\|node2_socket\|node3_socket' | grep -E -v grep -E | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true)
    sleep 2; sync 
  fi
  echo_out "[Abort] Ensuring any remaining processes are terminated"
  if [ "$EPOCH" != "" ]; then  
    PIDS_TO_TERMINATE=$(ps -ef | grep -E $WHOAMI | grep -E $EPOCH | grep -E -v "grep" | awk '{print $2}' | tr '\n' ' ')
  else
    echo_out "Assert: \$EPOCH is empty! in ctrl_c()!"
  fi
  echo_out "[Abort] Terminating these PID's: $PIDS_TO_TERMINATE"
  kill -9 $PIDS_TO_TERMINATE >/dev/null 2>&1
  echo_out "[Abort] What follows below is a call of finish(), the results are likely correct, but may be mangled due to the interruption"
  finish
  echo_out "[Abort] Done. Terminating reducer"
  exit 2
}

options_check(){
  # $1 to this procedure = $1 to the program - i.e. the SQL file to reduce
  if [ "$1" == "" -a "$INPUTFILE" == "" ]; then
    echo "Error: no input file given. Please give an SQL file to reduce as the first option to this script, or set inside the script as INPUTFILE=file_to_reduce.sql"
    echo "Terminating now."
    exit 1
  fi
  # Sudo check
  if [ "$(sudo -A echo 'test' 2>/dev/null)" != "test" ]; then 
    echo "Error: sudo is not available or requires a password. This script needs to be able to use sudo, without password, from the userID that invokes it ($(whoami))"
    echo "To get your setup correct, you may like to use a tool like visudo (use 'sudo visudo' or 'su' and then 'visudo') and consider adding the following line to the file:"
    echo "$(whoami)   ALL=(ALL)      NOPASSWD:ALL"
    echo "If you do not have sudo installed yet, try 'su' and then 'yum install sudo' or the apt-get equivalent"
    echo "Terminating now."
    exit 1
  fi
  # Note that instead of giving the SQL file on the cmd line, $INPUTFILE can be set (./process does so automaticaly using the #VARMOD# marker above)
  if [ $(sysctl -n fs.aio-max-nr) -lt 300000 ]; then
    echo "As fs.aio-max-nr on this system is lower than 300000, so you will likely run into BUG#12677594: INNODB: WARNING: IO_SETUP() FAILED WITH EAGAIN"
    echo "To prevent this from happening, please use the following command at your shell prompt (you will need to have sudo privileges):"
    echo "sudo sysctl -w fs.aio-max-nr=300000"
    echo "The setting can be verified by executing: sysctl fs.aio-max-nr"
    echo "Alternatively, you can add make the following settings to be system wide:"
    echo "sudo vi /etc/sysctl.conf           # Then, add the following two lines to the bottom of the file"
    echo "fs.aio-max-nr = 1048576"
    echo "fs.file-max = 6815744"
    echo "Terminating now."
    exit 1
  fi
  # Check if O_DIRECT is being used on tmpfs, which (when the original run was not on tmpfs) is not a 100% reproduce match, which may affect reproducibility
  # See http://bugs.mysql.com/bug.php?id=26662 for more info
  if $(echo $MYEXTRA | grep -E --binary-files=text -qi "MYEXTRA=.*O_DIRECT"); then
    if [ $WORKDIR_LOCATION -eq 1 -o $WORKDIR_LOCATION -eq 2 ]; then  # ramfs may not have this same issue, maybe '-o $WORKDIR_LOCATION -eq 2' can be removed?
      echo 'Error: O_DIRECT is being used in the MYEXTRA option string, and tmpfs (or ramfs) storage was specified, but because'
      echo 'of bug http://bugs.mysql.com/bug.php?id=26662 one would see a WARNING for this in the error log along the lines of;'
      echo '[Warning] InnoDB: Failed to set O_DIRECT on file ./ibdata1: OPEN: Invalid argument, continuing anyway.'
      echo "          O_DIRECT is known to result in 'Invalid argument' on Linux on tmpfs, see MySQL Bug#26662."
      echo 'So, reducer is exiting to allow you to change WORKDIR_LOCATION in the script to a non-tmpfs setting.'
      echo 'Note: this assertion currently shows for ramfs as well, yet it has not been established if ramfs also'        #
      echo '      shows the same problem. If it does not (modify the script in this section to get it to run with ramfs'  # ramfs, delete if ramfs is affected
      echo '      as a trial/test), then please remove ramfs, or, if it does, then please remove these 3 last lines.'     # 
      echo "Terminating now."
      exit 1
    fi
  fi 
  # This section could be expanded to check for any directory specified (by for instance checking for paths), not just the two listed here
  DIR_ISSUE=0
  if $(echo $MYEXTRA | grep -E --binary-files=text -qi "MYEXTRA=.*innodb_log_group_home_dir"); then DIR_ISSUE='innodb_log_group_home_dir'; fi
  if $(echo $MYEXTRA | grep -E --binary-files=text -qi "MYEXTRA=.*innodb_log_arch_dir"); then DIR_ISSUE='innodb_log_arch_dir'; fi
  if [ "$DIR_ISSUE" != "0" ]; then
    echo "Error: the $DIR_ISSUE option is being used in the MYEXTRA option string. This can lead to all sorts of problems;"
    echo 'Remember that reducer 1) is multi-threaded - i.e. it would access that particularly named directory for each started mysqld, which'
    echo 'clearly would result in issues, and 2) whilst reducer creates new directories for every trial (and for each thread), it would not do'
    echo 'anything for this hardcoded directory, so this directory would get used every time, again clearly resulting in issues, especially'
    echo 'when one considers that 3) running mysqld instances get killed once the achieved result (for example, issue discovered) is obtained.'
    echo 'Suggested course of action: remove this/these sort of options from the MYEXTRA string and see if the issue reproduces. This/these sort'
    echo 'of options often have little effect on reproducibility. Howerver, if found significant, reducer.sh can be expanded to cater for this/'
    echo 'these sort of options being in MYEXTRA by re-directing them to a per-trial (and per-thread) subdirectory of the trial`s rundir used.'
    echo 'Terminating reducer to allow this change to be made.'
    exit 1
  fi
  if [ $MODE -ge 6 ]; then
    if [ ! -d "$1" ]; then
        echo 'Error: A file name was given as input, but a directory name was expected.'
        echo "(MODE $MODE is set. Where you trying to use MODE 4 or lower?)"
        echo "Terminating now."
        exit 1
    fi
    if ! [ -d "$1/log/" -a -x "$1/log/" ]; then
      echo 'Error: No input directory containing a "/log" subdirectory was given, or the input directory could not be read.'
      echo 'Please specify a correct RQG vardir to reduce a multi-threaded testcase.'
      echo 'Example: ./reducer /starfish/data_WL1/vardir1_1000 -> to reduce ThreadSync trial 1000'
      echo "Terminating now."
      exit 1
    else
      TS_THREADS=$(ls -l $1/log/C[0-9]*T[0-9]*.sql | wc -l | tr -d '[\t\n ]*')
      # Making sure $TS_ELIMINATION_THREAD_ID is higher than number of threads to avoid 'unary operator expected' in cleanup_and_save during STAGE V
      TS_ELIMINATION_THREAD_ID=$[$TS_THREADS+1]  
      if [ $TS_THREADS -lt 1 ]; then
        echo 'Error: though input directory was found, no ThreadSync SQL trace files are present, or they could not be read.'
        echo "Please check the directory at $1"
        echo 'For the presence of 'C[0-9]*T[0-9]*.sql' files (for example, C1T10.sql).'
        echo 'Note: a data load file (such as CT2.sql or CT3.sql) alone is not sufficient: thread sql data would be missing.'
        echo "Terminating now."
        exit 1
      else
        TS_INPUTDIR="$1/log"
        TOKUDB_RUN_DETECTED=0
        if echo "${MYSAFE} ${MYEXTRA}" | grep -E --binary-files=text -qi "tokudb"; then TOKUDB_RUN_DETECTED=1; fi
        if [ ${DISABLE_TOKUDB_AUTOLOAD} -eq 0 ]; then
          if grep -E --binary-files=text -qi "tokudb" $TS_INPUTDIR/C[0-9]*T[0-9]*.sql; then TOKUDB_RUN_DETECTED=1; fi
        fi
        if [ ${TOKUDB_RUN_DETECTED} -eq 1 ]; then
          #if [ ${DISABLE_TOKUDB_AUTOLOAD} -eq 0 ]; then  # Just here for extra safety
          #  if ! echo "${MYSAFE} ${MYEXTRA}" | grep -E --binary-files=text -qi "plugin-load=tokudb=ha_tokudb.so"; then MYEXTRA="${MYEXTRA} --plugin-load=tokudb=ha_tokudb.so"; fi
          #  if ! echo "${MYSAFE} ${MYEXTRA}" | grep -E --binary-files=text -qi "tokudb-check-jemalloc"; then MYEXTRA="${MYEXTRA} --tokudb-check-jemalloc=0"; fi
          #fi
          #if [ -r /usr/lib64/libjemalloc.so.1 ]; then 
          #  export LD_PRELOAD=/usr/lib64/libjemalloc.so.1
          if [ -r `sudo find /usr/*lib*/ -name libjemalloc.so.1 | head -n1` ]; then
            export LD_PRELOAD=`sudo find /usr/*lib*/ -name libjemalloc.so.1 | head -n1`
          else
            if [ -r `sudo find /usr/local/*lib*/ -name libjemalloc.so.1 | head -n1` ]; then
              export LD_PRELOAD=`sudo find /usr/local/*lib*/ -name libjemalloc.so.1 | head -n1`
            else
              echo 'This run contains TokuDB SE SQL, yet jemalloc - which is required for TokuDB - was not found, please install it first'
              echo 'This can be done with a command similar to: $ yum install jemalloc'
              echo "Terminating now."
              exit 1
            fi
          fi
        fi
      fi
    fi
  else
    if [ -d "$1" ]; then
        echo 'Error: A directory was given as input, but a filename was expected.'
        echo "(MODE $MODE is set. Where you trying to use MODE 6 or higher?)"
        echo "Terminating now."
        exit 1
    fi
    if [ ! -s "$1" ]; then
      if [ ! -s $INPUTFILE ]; then
        echo 'Error: No input file was given, or the input file could not be read.'
        echo 'Please specify a single SQL file to reduce.'
        echo 'Example: ./reducer ~/1.sql     --> to process ~/1.sql'
        echo 'Also, please ensure input file name only contains [0-9a-zA-Z_-] characters'
        echo "Terminating now."
        exit 1
      fi
    else
      export -n INPUTFILE=$1  # export -n is not necessary for this script, but it is here to prevent pquery-prep-red.sh from seeing this as a adjustable var
    fi 
    TOKUDB_RUN_DETECTED=0
    if echo "${MYSAFE} ${MYEXTRA}" | grep -E --binary-files=text -qi "tokudb"; then TOKUDB_RUN_DETECTED=1; fi
    if [ ${DISABLE_TOKUDB_AUTOLOAD} -eq 0 ]; then
      if grep -E --binary-files=text -qi "tokudb" ${INPUTFILE}; then TOKUDB_RUN_DETECTED=1; fi
    fi
    if [ ${TOKUDB_RUN_DETECTED} -eq 1 ]; then
      #if [ ${DISABLE_TOKUDB_AUTOLOAD} -eq 0 ]; then  # Just here for extra safety
      #  if ! echo "${MYSAFE} ${MYEXTRA}" | grep -E --binary-files=text -qi "plugin-load=tokudb=ha_tokudb.so"; then MYEXTRA="${MYEXTRA} --plugin-load=tokudb=ha_tokudb.so"; fi
      #  if ! echo "${MYSAFE} ${MYEXTRA}" | grep -E --binary-files=text -qi "tokudb-check-jemalloc"; then MYEXTRA="${MYEXTRA} --tokudb-check-jemalloc=0"; fi
      #fi
      #if [ -r /usr/lib64/libjemalloc.so.1 ]; then 
      #  export LD_PRELOAD=/usr/lib64/libjemalloc.so.1
      if [ -r `sudo find /usr/*lib*/ -name libjemalloc.so.1 | head -n1` ]; then
        export LD_PRELOAD=`sudo find /usr/*lib*/ -name libjemalloc.so.1 | head -n1`
      else
        if [ -r `sudo find /usr/local/*lib*/ -name libjemalloc.so.1 | head -n1` ]; then
          export LD_PRELOAD=`sudo find /usr/local/*lib*/ -name libjemalloc.so.1 | head -n1`
        else
          echo 'This run contains TokuDB SE SQL, yet jemalloc - which is required for TokuDB - was not found, please install it first'
          echo 'This can be done with a command similar to: $ yum install jemalloc'
          echo "Terminating now."
          exit 1
        fi
      fi
    fi
  fi
  if [ $MODE -eq 0 ]; then
    if [ "${TIMEOUT_COMMAND}" != "" ]; then
      echo "Error: MODE is set to 0, and TIMEOUT_COMMAND is set. Both functions should not be used at the same time"
      echo "Use either MODE=0 (and set TIMEOUT_CHECK), or TIMEOUT_COMMAND in combination with some other MODE, for example MODE=2 or MODE=3"
      echo "Terminating now."
      exit 1
    fi
    if [ ${TIMEOUT_CHECK} -le 30 ]; then
      echo "Error: MODE=0 and TIMEOUT_CHECK<=30. When using MODE=0, set TIMEOUT_CHECK at least to: (2x the expected testcase duration lenght in seconds)+30 seconds extra!"
      echo "Terminating now."
      exit 1
    fi
    TIMEOUT_CHECK_REAL=$[ ${TIMEOUT_CHECK} - 30 ];
    if [ ${TIMEOUT_CHECK_REAL} -le 0 ]; then
      echo "Assert: TIMEOUT_CHECK_REAL<=0"
      echo "Terminating now."
      exit 1
    fi
    TIMEOUT_COMMAND="timeout --signal=SIGKILL ${TIMEOUT_CHECK}s"  # TIMEOUT_COMMAND var is used (hack) instead of adding yet another MODE0 specific variable
  fi
  if [ "${TIMEOUT_COMMAND}" != "" -a "$(timeout 2>&1 | grep -E -o 'information')" != "information" ]; then
    echo "Error: TIMEOUT_COMMAND is set, yet the timeout command does not seem to be available"
    echo "Terminating now."
    exit 1
  fi
  if [ $MODE -eq 3 -a $USE_TEXT_STRING -eq 1 ]; then
    if [ ! -s "$TEXT_STRING_LOC" ] ; then
      echo "Assert: MODE=3 and USE_TEXT_STRING=1, so reducer.sh looked for $TEXT_STRING_LOC, but this file was either not found, or is not script readable"
      exit
    fi
  fi 
  if [ $MODE -eq 2 ]; then
    if [ $PQUERY_MOD -eq 1 ]; then  # pquery client output testing run in MODE=2 - we need to make sure we have pquery client logging activated
      if [ "$(echo $PQUERY_EXTRA_OPTIONS | grep -E -io "log-client-output")" != "log-client-output" ]; then
        echo "Assert: PQUERY_MOD=1 && PQUERY_EXTRA_OPTIONS does not contain log-client-output, so not sure what file reducer.sh should check for TEXT occurence."
        exit 1
      fi
    fi
  fi
  BIN="${BASEDIR}/bin/mysqld"
  if [ ! -s "${BIN}" ]; then
    BIN="${BASEDIR}/bin/mysqld-debug"
    if [ ! -s "${BIN}" ]; then 
      echo "Assert: No mysqld or mysqld-debug binary was found in ${BASEDIR}/bin"
      echo 'Please check script contents/options and set the $BASEDIR variable correctly'
      echo "Terminating now."
      exit 1
    fi
  fi
  if [ $MODE -ne 0 -a $MODE -ne 1 -a $MODE -ne 2 -a $MODE -ne 3 -a $MODE -ne 4 -a $MODE -ne 5 -a $MODE -ne 6 -a $MODE -ne 7 -a $MODE -ne 8 -a $MODE -ne 9 ]; then
    echo "Error: Invalid MODE set: $MODE (valid range: 1-9)"
    echo 'Please check script contents/options ($MODE variable)'
    echo "Terminating now."
    exit 1
  fi
  if [ $MODE -eq 1 -o $MODE -eq 2 -o $MODE -eq 3 -o $MODE -eq 5 -o $MODE -eq 6 -o $MODE -eq 7 -o $MODE -eq 8 ]; then
    if [ ! -n "$TEXT" ]; then 
      echo "Error: MODE set to $MODE, but no \$TEXT variable was defined, or \$TEXT is blank"
      echo 'Please check script contents/options ($TEXT variable)'
      echo "Terminating now."
      exit 1
    fi
  fi
  if [[ $PXC_MOD -eq 1  || $GRP_RPL_MOD -eq 1 ]]; then
    PQUERY_MOD=1
    # ========= These are currently limitations of PXC/Group Replication mode. Feel free to extend reducer.sh to handle these ========
    #export -n MYEXTRA=""  # Serious shortcoming. Work to be done. PQUERY MYEXTRA variables will be added docker-compose.yml
    export -n FORCE_SPORADIC=0
    export -n SPORADIC=0
    export -n FORCE_SKIPV=0
    export -n SKIPV=1
    export -n MULTI_THREADS=0  # Original thought here was to avoid dozens of 3-container docker setups. This needs reviewing now that mysqld is used directly.
    # /==========
    if [ $MODE -eq 0 ]; then
      echo "Error: PXC/Group Replication mode is set to 1, and MODE=0 set to 0, but this option combination has not been tested/added to reducer.sh yet. Please do so!"
      echo "Terminating now."
      exit 1
    fi
    if [ "${TIMEOUT_COMMAND}" != "" ]; then
      echo "Error: PXC/Group Replication mode is set to 1, and TIMEOUT_COMMAND is set, but this option combination has not been tested/added to reducer.sh yet. Please do so!"
      echo "Terminating now."
      exit 1
    fi
    if [ $MODE -eq 1 -o $MODE -eq 6 ]; then
      echo "Error: Valgrind for 3 node PXC/Group Replication replay has not been implemented yet. Please do so! Free cookies afterwards!"
      echo "Terminating now."
      exit 1
    fi
    if [ $MODE -ge 6 -a $MODE -le 9 ]; then
      echo "Error: wrong option combination: MODE is set to $MODE (ThreadSync) and PXC/Group Replication mode is active"
      echo 'Please check script contents/options ($MODE and $PXC mode variables)'
      echo "Terminating now."
      exit 1
    fi
  fi
  if [ $PQUERY_MULTI -eq 1 ]; then
    PQUERY_MOD=1
  fi
  if [ $PQUERY_MOD -eq 1 ]; then
    if [ ! -r "$PQUERY_LOC" ]; then
      echo "Error: PQUERY_MOD is set to 1, but the pquery binary (as defined by PQUERY_LOC; currently set to '$PQUERY_LOC') is not available."
      echo 'Please check script contents/options ($PQUERY_MOD and $PQUERY_LOC variables)'
      echo "Terminating now."
      exit 1
    fi
  fi
  if [ $PQUERY_MULTI -gt 0 ]; then
    export -n FORCE_SKIPV=1
    MULTI_THREADS=$PQUERY_MULTI_THREADS
    if [ $PQUERY_MULTI_CLIENT_THREADS -lt 1 ]; then
      echo_out "Error: PQUERY_MULTI_CLIENT_THREADS is set to less then 1 ($PQUERY_MULTI_CLIENT_THREADS), while PQUERY_MULTI active, this does not work; reducer needs threads to be able to replay the issue"
      echo "Terminating now."
      exit 1
    elif [ $PQUERY_MULTI_CLIENT_THREADS -eq 1 ]; then
      echo_out "Warning: PQUERY_MULTI active, and PQUERY_MULTI_CLIENT_THREADS is set to 1; 1 thread for a multi-threaded issue does not seem logical. Proceeding, but this is highly likely incorrect. Please check. NOTE: There is at least one possible use case for this: proving that a sporadic mysqld startup can be reproduced (with a near-empty SQL file; i.e. the run is concerned with reproducing the startup issue, not reducing the SQL file)"
    elif [ $PQUERY_MULTI_CLIENT_THREADS -lt 5 ]; then
      echo_out "Warning: PQUERY_MULTI active, and PQUERY_MULTI_CLIENT_THREADS is set to $PQUERY_MULTI_CLIENT_THREADS, $PQUERY_MULTI_CLIENT_THREADS threads for reproducing a multi-threaded issue via random replay seems insufficient. You may want to increase PQUERY_MULTI_CLIENT_THREADS. Proceeding, but this is likely incorrect. Please check"
    fi
  fi
  if [ $REDUCE_GLIBC_OR_SS_CRASHES -gt 0 ]; then
    export -n MULTI_THREADS=1            # Likely not needed, because MULTI mode should never become active for REDUCE_GLIBC_OR_SS_CRASHES=1 (and there is a matching assert), 
    export -n MULTI_THREADS_INCREASE=0   # so it is here as a safety measure only FTM.
    export -n SLOW_DOWN_CHUNK_SCALING=1
    export -n SKIPV=1
    if [ $MODE -ne 3 -a $MODE -ne 4 ]; then
      echo "REDUCE_GLIBC_OR_SS_CRASHES is active, and MODE is set to MODE=$MODE, which is not supported (yet). Currently only modes 3 and 4 are supported when reducing GLIBC crashes"
      echo "Terminating now."
      exit 1
    fi
    if [[ $PXC_MOD -gt 0 || $GRP_RPL_MOD -eq 1 ]]; then
      echo "GLIBC testcase reduction is not yet supported for PXC_MOD=1 or GRP_RPL_MOD=1. This would be very complex to code, except perhaps for a single node cluster or for one node only. See source code for details. Search for 'GLIBC crash reduction'"
      echo "A workaround may be to see if this GLIBC crash reproduces on standard (non-cluster) mysqld also, which is likely."
      echo "Terminating now."
      exit 1
    fi
    if [ $PQUERY_MULTI -gt 0 ]; then
      echo "GLIBC testcase reduction is not yet supported for PQUERY_MULTI=1. This would be very complex to code. See source code for details. Search for 'GLIBC crash reduction'"
      echo "A workaround may be to see if this GLIBC crash reproduces using a single threaded execution, which in most cases is somewhat likely."
      echo "Terminating now."
      exit 1
    fi
  fi
  if [ $FORCE_SKIPV -gt 0 ]; then
    export -n FORCE_SPORADIC=1
    export -n SKIPV=1
  fi  
  if [ $FORCE_SPORADIC -gt 0 ]; then
    export -n STAGE1_LINES=3
    export -n SPORADIC=1
    export -n SLOW_DOWN_CHUNK_SCALING=1
  fi   
  if [ $MODE -eq 0 -a $FORCE_KILL=1 ]; then
    FORCE_KILL=0
  fi
  export -n MYEXTRA=`echo ${MYEXTRA} | sed 's|[ \t]*--no-defaults[ \t]*||g'`  # Ensuring --no-defaults is no longer part of MYEXTRA. Reducer already sets this itself always.
}

set_internal_options(){  # Internal options: do not modify!
  SEED=$(head -1 /dev/urandom | od -N 1 | awk '{print $2 }') 
  RANDOM=$SEED
  sleep 0.1$RANDOM  # Subreducer OS slicing?
  WHOAMI=$(whoami)
  if [ "$MULTI_REDUCER" != "1" ]; then  # This is the main reducer. For subreducers, EPOCH, SKIPV, SPORADIC is set in #VARMOD#
    EPOCH=$(date +%s)  # Used for /dev/shm work directory name and WORK_INIT, WORK_START etc. file names
    SKIPV=0
    SPORADIC=0
    MYUSER=$(whoami)
  else
    if [ "${EPOCH}" == "" ];    then echo "Assert: \$EPOCH is empty inside a subreducer! Check $(cd $(dirname $0) && pwd)/$0"; exit 1; fi
    if [ "${SKIPV}" == "" ];    then echo "Assert: \$SKIPV is empty inside a subreducer! Check $(cd $(dirname $0) && pwd)/$0"; exit 1; fi
    if [ "${SPORADIC}" == "" ]; then echo "Assert: \$SPORADIC is empty inside a subreducer! Check $(cd $(dirname $0) && pwd)/$0"; exit 1; fi
    if [ "${MYUSER}" == "" ];   then echo "Assert: \$MYUSER is empty inside a subreducer! Check $(cd $(dirname $0) && pwd)/$0"; exit 1; fi
  fi
  trap ctrl_c SIGINT  # Requires ${EPOCH} to be set already
  # Even if RQG is no longer used, the next line (i.e. including 'transforms') should NOT be modified. It provides backwards compatibility with RQG and it provides a long unique 
  # string which is unlikely to be present in testcases (it's used in grep -E -v a few times below). "DROP DATABASE test;CREATE DATABASE test;USE test;" would be more/too? generic.
  DROPC="DROP DATABASE transforms;CREATE DATABASE transforms;DROP DATABASE test;CREATE DATABASE test;USE test;"
  STARTUPCOUNT=0
  ATLEASTONCE="[]"
  TRIAL=1
  STAGE='0'
  STUCKTRIAL=0
  NOISSUEFLOW=0
  CHUNK_LOOPS_DONE=99999999999   # Has to be exactly 99999999999 to ensure that determine_chunk() at least runs once
  C_COL_COUNTER=1
  TS_ELIMINATED_THREAD_COUNT=0
  TS_ORIG_VARS_FLAG=0
  TS_DEBUG_SYNC_REQUIRED_FLAG=0  # Untill proven otherwise
  TS_TE_DIR_SWAP_DONE=0
}

kill_multi_reducer(){
  if [ $(ps -ef | grep -E subreducer | grep -E $WHOAMI | grep -E $EPOCH | grep -E -v grep -E | awk '{print $2}' | wc -l) -ge 1 ]; then
    PIDS_TO_TERMINATE=$(ps -ef | grep -E subreducer | grep -E $WHOAMI | grep -E $EPOCH | grep -E -v grep -E | awk '{print $2}' | sort -u | tr '\n' ' ')
    echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Terminating these PID's: $PIDS_TO_TERMINATE"
    while [ $(ps -ef | grep -E subreducer | grep -E `whoami` | grep -E $EPOCH | grep -E -v grep -E | awk '{print $2}' | wc -l) -ge 1 ]; do
      for t in $(ps -ef | grep -E subreducer | grep -E `whoami` | grep -E $EPOCH | grep -E -v grep -E | awk '{print $2}' | sort -u); do
        kill -9 $t 2>/dev/null
        wait $t 2>/dev/null  # Prevents "<process id> Killed" messages
      done
      sync; sleep 3
      if [ $(ps -ef | grep -E subreducer | grep -E `whoami` | grep -E $EPOCH | grep -E -v grep -E | awk '{print $2}' | wc -l) -ge 1 ]; then
        sync; sleep 20  # Extended wait for processes to terminate
        if [ $(ps -ef | grep -E subreducer | grep -E `whoami` | grep -E $EPOCH | grep -E -v grep -E | awk '{print $2}' | wc -l) -ge 1 ]; then
          echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] WARNING: $(ps -ef | grep -E subreducer | grep -E `whoami` | grep -E $EPOCH | grep -E -v grep -E | wc -l) subreducer processes still exists after they were killed, re-attempting kill"
        fi
      fi
    done
  fi
}

multi_reducer(){
  MULTI_FOUND=0
  # This function handles starting and checking subreducer threads used for verification AND simplification of sporadic issues (as such it is the parent 
  # function watching over multiple [seperately started] subreducer threads, each child containing the written MULTI_REDUCER=1 setting set in #VARMOD# - 
  # thereby telling reducer it is a child process)
  # This function does not need to know if reducer is reducing a single or multi-threaded testcase and what MODE is used as all these options are passed
  # verbatim to the child ($1 to the program is $1 to the child, and all ather settings are copied into the child process below)
  if [ $REDUCE_GLIBC_OR_SS_CRASHES -gt 0 ]; then
    echo_out "ASSERT: REDUCE_GLIBC_OR_SS_CRASHES is active, and we ended up in multi_reducer() function. This should not be possible as REDUCE_GLIBC_OR_SS_CRASHES uses a single thread only."
  fi
  if [ "$STAGE" = "V" ]; then
    echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Starting $MULTI_THREADS verification subreducer threads to verify if the issue is sporadic ($WORKD/subreducer/)"
    SKIPV=0
    SPORADIC=0 # This will quickly be overwritten by the line "SPORADIC=1  # Sporadic unless proven otherwise" below. So, need to check if this is needed here (may be needed for ifthen statements using this variable. Needs research and/or testing.
  else
    echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Starting $MULTI_THREADS simplification subreducer threads to reduce the issue further ($WORKD/subreducer/)"
    SKIPV=1 # For subreducers started for simplification (STAGE1+), verify/initial simplification should be skipped as this was done already by the parent/main reducer (i.e. just above)
  fi

  echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Ensuring any old subreducer processes are terminated"
  kill_multi_reducer

  # Create (or remove/create) main multi-reducer path
  rm -Rf $WORKD/subreducer/
  sync; sleep 0.5
  if [ -d $WORKD/subreducer/ ]; then
    echo_out "ASSERT: $WORKD/subreducer/ still exists after it has been deleted"
    echo "Terminating now."
    exit 1
  fi
  mkdir $WORKD/subreducer/

  # Choose a random port number in 40K range, check if free, increase if needbe
  MULTI_MYPORT=$[40000 + ( $RANDOM % ( $[ 9999 - 1 ] + 1 ) ) + 1 ] 
  while :; do
    ISPORTFREE=$(netstat -an | grep -E $MULTI_MYPORT | wc -l | tr -d '[\t\n ]*')
    if [ $ISPORTFREE -ge 1 ]; then
      MULTI_MYPORT=$[$MULTI_MYPORT+100]  #+100 to avoid 'clusters of ports'
    else
      break
    fi
  done

  TXT_OUT="$ATLEASTONCE [Stage $STAGE] [MULTI] Forking subreducer threads [PIDs]:"
  for t in $(eval echo {1..$MULTI_THREADS}); do
    # Create individual subreducer paths
    export WORKD$t="$WORKD/subreducer/$t"
    export MULTI_WORKD=$(eval echo $(echo '$WORKD'"$t"))
    mkdir $MULTI_WORKD

    FIXED_TEXT=$(echo "$TEXT" | sed "s|:|\\\:|g")
    cat $0 \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:MULTI_REDUCER=1\n#VARMOD#:" \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:EPOCH=$EPOCH\n#VARMOD#:" \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:MODE=$MODE\n#VARMOD#:" \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:TEXT=\"$FIXED_TEXT\"\n#VARMOD#:" \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:MODE5_COUNTTEXT=$MODE5_COUNTTEXT\n#VARMOD#:" \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:SKIPV=$SKIPV\n#VARMOD#:" \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:SPORADIC=$SPORADIC\n#VARMOD#:" \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:PQUERY_MULTI_CLIENT_THREADS=$PQUERY_MULTI_CLIENT_THREADS\n#VARMOD#:" \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:PQUERY_MULTI_QUERIES=$PQUERY_MULTI_QUERIES\n#VARMOD#:" \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:TS_TRXS_SETS=$TS_TRXS_SETS\n#VARMOD#:" \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:TS_DBG_CLI_OUTPUT=$TS_DBG_CLI_OUTPUT\n#VARMOD#:" \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:BASEDIR=\"$BASEDIR\"\n#VARMOD#:" \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:MYPORT=\"$MULTI_MYPORT\"\n#VARMOD#:" \
      | sed -e "0,/#VARMOD#/s:#VARMOD#:MYUSER=\"$MYUSER\"\n#VARMOD#:" > $MULTI_WORKD/subreducer

    chmod +x $MULTI_WORKD/subreducer
    sleep 0.2  # To avoid "InnoDB: Error: pthread_create returned 11" collisions/overloads
    $($MULTI_WORKD/subreducer $1 >/dev/null 2>/dev/null) >/dev/null 2>/dev/null &
    PID=$!
    export MULTI_PID$t=$PID
    TXT_OUT="$TXT_OUT #$t [$PID]"
    
    # Take the following available port
    MULTI_MYPORT=$[$MULTI_MYPORT+1]
    while :; do
      ISPORTFREE=$(netstat -an | grep -E $MULTI_MYPORT | wc -l | tr -d '[\t\n ]*')
      if [ $ISPORTFREE -ge 1 ]; then
        MULTI_MYPORT=$[$MULTI_MYPORT+100]  #+100 to avoid 'clusters of ports'
      else
        break
      fi
    done
  done
  echo_out "$TXT_OUT"

  if [ "$STAGE" = "V" ]; then
    # Wait for forked processes to terminate
    echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Waiting for all forked verification subreducer threads to finish/terminate"
    TXT_OUT="$ATLEASTONCE [Stage $STAGE] [MULTI] Finished/Terminated verification subreducer threads:"
    for t in $(eval echo {1..$MULTI_THREADS}); do
      # An ideal situation would be to have a check here for 'Failed to start mysqld server' in the subreducer logs. However, this would require a change
      # to how this section works; the "wait" for PID would have to be changed to some sort of loop. However, as a stopped verify thread (1 in 10 for starters)
      # is quickly surpassed by a new set of threads - i.e. after 10 threads, 20 are started (a new run with +10 threads) - it is not deemed very necessary
      # to change this atm. This error also would only show on very busy servers. However, this check SHOULD be done for non-verify MULTI stages, as for
      # simplification, all threads keep running (if they remain live) untill a simplified testcase is found. Thus, if 8 out of 10 threads sooner or later
      # end up with 'Failed to start mysqld server', then only 2 threads would remain that try and reproduce the issue (till ifinity). The 'Failed to start 
      # mysqld server' is seen on very busy servers (presumably some timeout hit). This second part (starting with 'However,...' is implemented already below.
      wait $(eval echo $(echo '$MULTI_PID'"$t"))
      TXT_OUT="$TXT_OUT #$t"
      echo_out_overwrite "$TXT_OUT"
      if [ $t -eq 20 -a $MULTI_THREADS -gt 20 ]; then
        echo_out "$TXT_OUT"
        TXT_OUT="$ATLEASTONCE [Stage $STAGE] [MULTI] Finished/Terminated verification subreducer threads:"
      fi
    done
    echo_out "$TXT_OUT"
    echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] All verification subreducer threads have finished/terminated"
  else
    # Wait for one of the forked processes to find a better reduction file
    echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Waiting for any forked simplifation subreducer threads to find a shorter file (Issue is sporadic: this will take time)"
    FOUND_VERIFIED=0
    while [ $FOUND_VERIFIED -eq 0 ]; do
      for t in $(eval echo {1..$MULTI_THREADS}); do
        export MULTI_WORKD=$(eval echo $(echo '$WORKD'"$t"))
        # Check if issue was found (i.e. $MULTI_WORKD/VERIFIED file is present). End both loops (while+for) if so
        if [ -s $MULTI_WORKD/VERIFIED ]; then
          sleep 1.5  # Give subreducer script time to write out the file fully
          echo_out_overwrite "$ATLEASTONCE [Stage $STAGE] [MULTI] Terminating simplification subreducer threads... "
          for i in $(eval echo {1..$MULTI_THREADS}); do
            PID_TO_KILL=$(eval echo $(echo '$MULTI_PID'"$i"))
            kill -9 $PID_TO_KILL 2>/dev/null
            wait $PID_TO_KILL 2>/dev/null  # Prevents "<process id> Killed" messages
          done
          sleep 4  # Make sure disk based activity is finished
          # Make sure all subprocessed are gone
          for i in $(eval echo {1..$MULTI_THREADS}); do
            PID_TO_KILL=$(eval echo $(echo '$MULTI_PID'"$i"))
            kill -9 $PID_TO_KILL 2>/dev/null
            wait $PID_TO_KILL 2>/dev/null  # Prevents "<process id> Killed" messages
          done
          sleep 2
          echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Terminating simplification subreducer threads... done"
          cp -f $(cat $MULTI_WORKD/VERIFIED | grep -E "WORKO" | sed -e 's/^.*://' -e 's/[ ]*//g') $WORKF
          if [ -r "$WORKO" ]; then  # First occurence: there is no $WORKO yet
            cp -f $WORKO ${WORKO}.prev
            # Save a testcase backup (this is useful if [oddly] the issue now fails to reproduce)
            echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Previous good testcase backed up as $WORKO.prev"
          fi
          cp -f $WORKF $WORKO
          ATLEASTONCE="[*]"  # The issue was seen at least once
          echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Thread #$t reproduced the issue: testcase saved in $WORKO"
          FOUND_VERIFIED=1  # Outer loop terminate setup
          break  # Inner loop terminate
        fi
        # Check if this subreducer ($MULTI_PID$t) is still running. For more info, see "However, ..." in few lines of comments above.
        PID_TO_CHECK=$(eval echo $(echo '$MULTI_PID'"$t"))
        if [ "$(ps -p$PID_TO_CHECK | grep -E -o $PID_TO_CHECK)" != "$PID_TO_CHECK" ]; then
          RESTART_WORKD=$(eval echo $(echo '$WORKD'"$t"))
          rm -Rf $RESTART_WORKD/[^s]*  # Remove all files, except for subreducer script
          $($RESTART_WORKD/subreducer $1 >/dev/null 2>/dev/null) >/dev/null 2>/dev/null &
          export MULTI_PID$t=$!
          INIT_FILE_USED=
          if [[ "${MEXTRA}" == *"init[-_]file"* ]]; then INIT_FILE_USED="or any file(s) called using --init-file which is present in \$MYEXTRA, "; fi
          # The following can be improved much further: this script can actually check for 1) self-existence, 2) workdir existence, 3) any --init-file called SQL files existence. And if 1/2/3 are handled as such, the error message below can be made much nicer. For example "ERROR: This script (./reducer<nr>.sh) was deleted! Terminating." etc. Make sure that any terminates of scripts are done properly, i.e. if possible still report last optimized file etc.
          echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Thread #$t disappeared, restarted thread with PID #$(eval echo $(echo '$MULTI_PID'"$t")) (This can happen on busy servers, - or - if this message is looping constantly; did you accidentally delete and/or recreate this script, it's working directory, or the mysql base directory ${INIT_FILE_USED}while this script was running?)"  # Due to mysqld startup timeouts etc. | Check last few lines of subreducer log to find reason (you may need a pause above before the thread is restarted!)
        fi
        sleep 1  # Hasten slowly, server already busy with subreducers
      done
    done
    echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] All subreducer threads have finished/terminated"
  fi

  if [ "$STAGE" = "V" ]; then
    # Check thread outcomes
    TXT_OUT=""
    for t in $(eval echo {1..$MULTI_THREADS}); do
      export MULTI_WORKD=$(eval echo $(echo '$WORKD'"$t"))
      if [ -s $MULTI_WORKD/VERIFIED ]; then
        ATLEASTONCE="[*]"  # The issue was seen at least once
        MULTI_FOUND=$[$MULTI_FOUND+1]
        TXT_OUT="$TXT_OUT #$t"
      fi
    done
    # Report on outcomes
    SPORADIC=1  # Sporadic unless proven otherwise (set below)
    if [ $MULTI_FOUND -eq 0 ]; then 
      echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Threads which reproduced the issue: <none>"
    elif [ $MULTI_FOUND -eq $MULTI_THREADS ]; then
      echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Threads which reproduced the issue:$TXT_OUT"
      if [ $FORCE_SPORADIC -gt 0 ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] All threads reproduced the issue: this issue is not considered sporadic"
        echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] However, as the FORCE_SPORADIC is on, sporadic testcase reduction will commence"
      else
        echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] All threads reproduced the issue: this issue is not sporadic"
        echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Note: if this issue proves sporadic in actual reduction (slow/stalling reduction), use the FORCE_SPORADIC=1 setting"
        SPORADIC=0
      fi
      if [ $MODE -lt 6 ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Ensuring any rogue subreducer processes are terminated"
        kill_multi_reducer
      fi
    elif [ $MULTI_FOUND -lt $MULTI_THREADS ]; then
      echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Threads which reproduced the issue:$TXT_OUT"
      echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Only $MULTI_FOUND out of $MULTI_THREADS threads reproduced the issue: this issue is sporadic"
      # Do not enable SLOW_DOWN_CHUNK_SCALING=1 here! It is not suited for MULTI mode, as subreducers will then have a fully-static chunck size because of the main reducer.sh keeping the same chunk size, and the subreducers initially take a copy, and instead of scaling their chunks, they keep the chunks from the main one... or something. The visual effect of enabling this here is that x in "Remaining number of lines in input file: x" remains static, acrross many "Thread #y reproduced the issue" trials.
    fi
    return $MULTI_FOUND
  fi
}

multi_reducer_decide_input(){
  echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Deciding which verified output file to keep out of $MULTI_FOUND threads"
  # This function, based on checking the outcome of the various threads started in multi_reducer() decides which verified input file (from the various
  # subreducer threads) will be kept. It would be best to keep a file with TRIAL=1 (obviously from a succesful verification thread) since such a file
  # would have had maximum simplification applied. As soon such a file is found, reducer can use that one and stop searching.
  LOWEST_TRIAL_LEVEL_SEEN=100
  for t in $(eval echo {1..$MULTI_THREADS}); do
    export MULTI_WORKD=$(eval echo $(echo '$WORKD'"$t"))
    if [ -s $MULTI_WORKD/VERIFIED ]; then
      TRIAL_LEVEL=$(cat $MULTI_WORKD/VERIFIED | grep -E "TRIAL" | sed -e 's/^.*://' -e 's/[ ]*//g')
      if [ $TRIAL_LEVEL -eq 1 ]; then
        # Highest optimization possible, use file and exit
        cp -f $(cat $MULTI_WORKD/VERIFIED | grep -E "WORKO" | sed -e 's/^.*://' -e 's/[ ]*//g') $WORKF
        echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Found verified, maximum initial simplification file, at thread #$t: Using it as new input file"
        if [ -r $MULTI_WORKD/MYEXTRA ]; then
          MYEXTRA=$(cat $MULTI_WORKD/MYEXTRA)
        fi
        break
      elif [ $TRIAL_LEVEL -lt $LOWEST_TRIAL_LEVEL_SEEN ]; then
        LOWEST_TRIAL_LEVEL_SEEN=$TRIAL_LEVEL
        cp -f $(cat $MULTI_WORKD/VERIFIED | grep -E "WORKO" | sed -e 's/^.*://' -e 's/[ ]*//g') $WORKF
        echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Found verified, level $TRIAL_LEVEL simplification file, at thread #$t: Using it as new input file, unless better is found"
        if [ -r $MULTI_WORKD/MYEXTRA ]; then
          MYEXTRA=$(cat $MULTI_WORKD/MYEXTRA)
        fi
      fi
    fi 
  done
  echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] Removing verify stage subreducer directory"
  rm -Rf $WORKD/subreducer/  # It should be fine to remove this verify stage subreducer directory here, and save space, but this needs over-time confirmation. Added RV 25-10-2016
}

TS_init_all_sql_files(){
  # DATA thread (Single threaded init by RQG - saved as CT[0-9].sql, usually CT2.sql or CT3.sql)
  TSDATA_COUNT=$(ls $TS_INPUTDIR/CT[0-9]*.sql | wc -l | tr -d '[\t\n ]*')
  if [ $TSDATA_COUNT -eq 1 ]; then
    TS_DATAINPUTFILE=$(ls $TS_INPUTDIR/CT[0-9]*.sql)
  else
    echo 'ASSERT: do not know how to handle more than one ThreadSync data input file [yet].'
    echo "Terminating now."
    exit 1
  fi

  # SQL threads (Multi-threaded SQL run by RQG - saved as C[0-9]*T[0-9]*.sql)
  TS_REAL_THREAD=0
  for TSSQL in $(ls $TS_INPUTDIR/C[0-9]*T[0-9]*.sql | sort); do 
    TS_REAL_THREAD=$[$TS_REAL_THREAD+1]
    export TS_SQLINPUTFILE$TS_REAL_THREAD=$TSSQL
  done
  if [ ! $TS_REAL_THREAD -eq $TS_THREADS ]; then
    echo 'ASSERT: $TS_REAL_THREAD != $TS_THREADS: '"$TS_REAL_THREAD != $TS_THREADS"
    echo "Terminating now."
    exit 1
  fi
  if [ $TS_ORIG_VARS_FLAG -eq 0 ]; then
    TS_ORIG_DATAINPUTFILE=$TS_DATAINPUTFILE
    TS_ORIG_THREADS=$TS_THREADS
    TS_ORIG_VARS_FLAG=1
  fi
  echo_out "[Init] Input directory: $TS_INPUTDIR/"
  echo_out "[Init] Input files: Data: $TS_DATAINPUTFILE"
  for t in $(eval echo {1..$TS_THREADS}); do 
    export WORKF$t="$WORKD/in$t.sql"
    export WORKT$t="$WORKD/in$t.tmp"
    export WORKO$t=$(eval echo $(echo '$TS_SQLINPUTFILE'"$t") | sed 's/$/_out/' | sed "s/^.*\//$(echo $WORKD | sed 's/\//\\\//g')\/out\//")
    TS_FILE_NAME=$(eval echo $(echo '$TS_SQLINPUTFILE'"$t"))
    echo_out "[Init] Input files: Thread $t: $TS_FILE_NAME"
  done
  # Copy of INPUTFILE to WORKF files
  # DDL data thread load is done in run_sql_code. Here reducer handles the SQL threads 
  for t in $(eval echo {1..$TS_THREADS}); do 
    cat $(eval echo $(echo '$TS_SQLINPUTFILE'"$t")) > $(eval echo $(echo '$WORKF'"$t"))
  done
}

init_empty_port(){
  # Choose a random port number in 30K range, check if free, increase if needbe
  MYPORT=$[30000 + ( $RANDOM % ( $[ 9999 - 1 ] + 1 ) ) + 1 ] 
  while :; do
    ISPORTFREE=$(netstat -an | grep -E $MYPORT | wc -l | tr -d '[\t\n ]*')
    if [ $ISPORTFREE -ge 1 ]; then
      MYPORT=$[$MYPORT+100]  #+100 to avoid 'clusters of ports'
    else
      break
    fi
  done
}

init_workdir_and_files(){
  # Make sure that the directory does not exist yet
  while :; do
    if [ "$MULTI_REDUCER" == "1" ]; then  # This is a subreducer
      WORKD=$(dirname $0)
      break
    fi
    if [ $WORKDIR_LOCATION -eq 3 ]; then
      if ! [ -d "$WORKDIR_M3_DIRECTORY/" -a -x "$WORKDIR_M3_DIRECTORY/" ]; then
        echo 'Error: WORKDIR_LOCATION=3 (a specific storage location) is set, yet WORKDIR_M3_DIRECTORY (set to $WORKDIR_M3_DIRECTORY) does not exist, or could not be read.'
        echo "Terminating now."
        exit 1
      fi
      if [ $(df -k -P 2>&1 | grep -E -v "docker.devicemapper" | grep -E "$WORKDIR_M3_DIRECTORY" | awk '{print $4}') -lt 3500000 ]; then
        echo "Error: $WORKDIR_M3_DIRECTORY does not have enough free space (3.5Gb free space required)"
        echo "Terminating now."
        exit 1
      fi
      WORKD="$WORKDIR_M3_DIRECTORY/$EPOCH"
    elif [ $WORKDIR_LOCATION -eq 2 ]; then
      if ! [ -d "/mnt/ram/" -a -x "/mnt/ram/" ]; then
        echo 'Error: ramfs storage usage was specified (WORKDIR_LOCATION=2), yet /mnt/ram/ does not exist, or could not be read.'
        echo 'Suggestion: setup a ram drive using the following commands at your shell prompt:'
        echo 'sudo mkdir -p /mnt/ram; sudo mount -t ramfs -o size=4g ramfs /mnt/ram; sudo chmod -R 777 /mnt/ram;'
        echo "Terminating now."
        exit 1
      fi
      if [ $(df -k -P 2>&1 | grep -E -v "docker/devicemapper.*Permission denied" | grep -E "/mnt/ram$" | awk '{print $4}' | grep -E -v 'docker.devicemapper') -lt 3500000 ]; then
        echo 'Error: /mnt/ram/ does not have enough free space (3.5Gb free space required)'
        echo "Terminating now."
        exit 1
      fi
      WORKD="/mnt/ram/$EPOCH"
    elif [ $WORKDIR_LOCATION -eq 1 ]; then
      if ! [ -d "/dev/shm/" -a -x "/dev/shm/" ]; then
        echo 'Error: tmpfs storage usage was specified (WORKDIR_LOCATION=1), yet /dev/shm/ does not exist, or could not be read.'
        echo 'Suggestion: check the location of tmpfs using the 'df -h' command at your shell prompt and change the script to match'
        echo "Terminating now."
        exit 1
      fi
      if [ $(df -k -P 2>&1 | grep -E -v "docker/devicemapper.*Permission denied" | grep -E "/dev/shm$" | awk '{print $4}' | grep -E -v 'docker.devicemapper') -lt 3500000 ]; then
        echo 'Error: /dev/shm/ does not have enough free space (3.5Gb free space required)'
        echo "Terminating now."
        exit 1
      fi
      WORKD="/dev/shm/$EPOCH"
    else
      if ! [ -d "/tmp/" -a -x "/tmp/" ]; then
        echo 'Error: /tmp/ storage usage was specified (WORKDIR_LOCATION=0), yet /tmp/ does not exist, or could not be read.'
        echo "Terminating now."
        exit 1
      fi
      if [ $(df -k -P 2>&1 | grep -E -v "docker/devicemapper.*Permission denied" | grep -E "[ \t]/$" | awk '{print $4}' | grep -E -v 'docker.devicemapper') -lt 3500000 ]; then
        echo 'Error: The drive mounted as / does not have enough free space (3.5Gb free space required)'
        echo "Terminating now."
        exit 1
      fi
      WORKD="/tmp/$EPOCH"
    fi
    if [ -d $WORKD ]; then
      EPOCH=$[EPOCH-1]
    else
      break
    fi
  done
  if [ "$MULTI_REDUCER" != "1" ]; then  # This is the main reducer
    mkdir $WORKD
  fi
  mkdir $WORKD/data $WORKD/tmp
  chmod -R 777 $WORKD
  touch $WORKD/reducer.log
  echo_out "[Init] Workdir: $WORKD"
  export TMP=$WORKD/tmp
  if [ $REDUCE_GLIBC_OR_SS_CRASHES -gt 0 ]; then echo_out "[Init] Console typescript log for REDUCE_GLIBC_OR_SS_CRASHES: /tmp/reducer_typescript${TYPESCRIPT_UNIQUE_FILESUFFIX}.log"; fi
  echo_out "[Init] Temporary storage directory (TMP environment variable) set to $TMP"
  # jemalloc configuration for TokuDB plugin
  JE1="if [ \"\${JEMALLOC}\" != \"\" -a -r \"\${JEMALLOC}\" ]; then export LD_PRELOAD=\${JEMALLOC}"
  #JE2=" elif [ -r /usr/lib64/libjemalloc.so.1 ]; then export LD_PRELOAD=/usr/lib64/libjemalloc.so.1"
  #JE3=" elif [ -r /usr/lib/x86_64-linux-gnu/libjemalloc.so.1 ]; then export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.1"
  JE2=" elif [ -r \`sudo find /usr/*lib*/ -name libjemalloc.so.1 | head -n1\` ]; then export LD_PRELOAD=\`sudo find /usr/*lib*/ -name libjemalloc.so.1 | head -n1\`"
  JE3=" elif [ -r \${BASEDIR}/lib/mysql/libjemalloc.so.1 ]; then export LD_PRELOAD=\${BASEDIR}/lib/mysql/libjemalloc.so.1"
  JE4=" else echo 'Warning: jemalloc was not loaded as it was not found (this is fine for MS, but do check ./${EPOCH}_mybase to set correct jemalloc location for PS)'; fi" 

  WORKF="$WORKD/in.sql"
  WORKT="$WORKD/in.tmp"
  WORK_BASEDIR=$(echo $INPUTFILE | sed "s|/[^/]\+$|/|;s|$|${EPOCH}_mybase|")
  WORK_INIT=$(echo $INPUTFILE | sed "s|/[^/]\+$|/|;s|$|${EPOCH}_init|")
  WORK_START=$(echo $INPUTFILE | sed "s|/[^/]\+$|/|;s|$|${EPOCH}_start|")
  WORK_START_VALGRIND=$(echo $INPUTFILE | sed "s|/[^/]\+$|/|;s|$|${EPOCH}_start_valgrind|")
  WORK_STOP=$(echo $INPUTFILE | sed "s|/[^/]\+$|/|;s|$|${EPOCH}_stop|")
  WORK_RUN=$(echo $INPUTFILE | sed "s|/[^/]\+$|/|;s|$|${EPOCH}_run|")
  WORK_GDB=$(echo $INPUTFILE | sed "s|/[^/]\+$|/|;s|$|${EPOCH}_gdb|")
  WORK_PARSE_CORE=$(echo $INPUTFILE | sed "s|/[^/]\+$|/|;s|$|${EPOCH}_parse_core|")
  WORK_HOW_TO_USE=$(echo $INPUTFILE | sed "s|/[^/]\+$|/|;s|$|${EPOCH}_how_to_use.txt|")
  if [ $PQUERY_MOD -eq 1 ]; then
    WORK_RUN_PQUERY=$(echo $INPUTFILE | sed "s|/[^/]\+$|/|;s|$|${EPOCH}_run_pquery|")
    WORK_PQUERY_BIN=$(echo $INPUTFILE | sed "s|/[^/]\+$|/|;s|$|${EPOCH}_|" | sed "s|$|$(echo $PQUERY_LOC | sed 's|.*/||')|")
  fi
  WORK_CL=$(echo $INPUTFILE | sed "s|/[^/]\+$|/|;s|$|${EPOCH}_cl|")
  WORK_OUT=$(echo $INPUTFILE | sed "s|/[^/]\+$|/|;s|$|${EPOCH}.sql|")
  if [ $MODE -ge 6 ]; then
    mkdir $WORKD/out
    mkdir $WORKD/log
    TS_init_all_sql_files 
  else
    if [ "$MULTI_REDUCER" != "1" ]; then  # This is the parent/main reducer
      WORKO=$(echo $INPUTFILE | sed 's/$/_out/')
    else
      WORKO=$(echo $INPUTFILE | sed 's/$/_out/' | sed "s/^.*\//$(echo $WORKD | sed 's/\//\\\//g')\//")  # Save output file in individual workdirs
    fi
    echo_out "[Init] Input file: $INPUTFILE"
    # Initial INPUTFILE to WORKF copy
    (echo "$DROPC"; (cat $INPUTFILE | grep -E --binary-files=text -v "$DROPC")) > $WORKF
  fi
  if [ $PXC_MOD -eq 1 ]; then
    echo_out "[Init] PXC Node #1 Client: $BASEDIR/bin/mysql -uroot -S${node1}/node1_socket.sock"
    echo_out "[Init] PXC Node #2 Client: $BASEDIR/bin/mysql -uroot -S${node2}/node2_socket.sock"
    echo_out "[Init] PXC Node #3 Client: $BASEDIR/bin/mysql -uroot -S${node3}/node3_socket.sock"
  elif [ $GRP_RPL_MOD -eq 1 ]; then
    echo_out "[Init] Group Replication Node #1 Client: $BASEDIR/bin/mysql -uroot -S${node1}/node1_socket.sock"
    echo_out "[Init] Group Replication Node #2 Client: $BASEDIR/bin/mysql -uroot -S${node2}/node2_socket.sock"
    echo_out "[Init] Group Replication Node #3 Client: $BASEDIR/bin/mysql -uroot -S${node3}/node3_socket.sock"
  else
    echo_out "[Init] Server: ${BIN} (as $MYUSER)"
    if [ $REDUCE_GLIBC_OR_SS_CRASHES -gt 0 ]; then
      echo_out "[Init] Client: $BASEDIR/bin/mysql -uroot -S$WORKD/socket.sock"
    else
      echo_out "[Init] Client (When MULTI mode is not active): $BASEDIR/bin/mysql -uroot -S$WORKD/socket.sock"
    fi
  fi
  if [ $SKIPSTAGEBELOW -gt 0 ]; then echo_out "[Init] SKIPSTAGEBELOW active. Stages up to and including $SKIPSTAGEBELOW are skipped"; fi
  if [ $SKIPSTAGEABOVE -lt 9 ]; then echo_out "[Init] SKIPSTAGEABOVE active. Stages above and including $SKIPSTAGEABOVE are skipped"; fi
  if [ $PQUERY_MULTI -gt 0 ]; then
    echo_out "[Init] PQUERY_MULTI mode active, so automatically set PQUERY_MOD=1: testcase reduction will be done using pquery"
    if [ $PQUERY_REVERSE_NOSHUFFLE_OPT -gt 0 ]; then
      echo_out "[Init] PQUERY_MULTI mode active, PQUERY_REVERSE_NOSHUFFLE_OPT on: Semi-true multi-threaded testcase reduction using pquery sequential replay commencing";
    else
      echo_out "[Init] PQUERY_MULTI mode active, PQUERY_REVERSE_NOSHUFFLE_OPT off: True multi-threaded testcase reduction using pquery random replay commencing";
    fi
  else
    if [ $PQUERY_REVERSE_NOSHUFFLE_OPT -gt 0 ]; then
      if [ $FORCE_SKIPV -gt 0 -a $FORCE_SPORADIC -gt 0 ]; then
        echo_out "[Init] PQUERY_REVERSE_NOSHUFFLE_OPT turned on. Replay will be random instead of sequential (whilst still using a single thread client per mysqld)"
      else
        echo_out "[Init] PQUERY_REVERSE_NOSHUFFLE_OPT turned on. Replay will be random instead of sequential (whilst still using a single thread client per mysqld). This setting is best combined with FORCE_SKIPV=1 and FORCE_SPORADIC=1 ! Please edit the settings, unless you know what you're doing"
      fi
    fi
  fi
  if [ $MODE -eq 3 -a $USE_TEXT_STRING -eq 1 ]; then
    echo_out "[Init] MODE=3 and USE_TEXT_STRING turned on. Scanning for TEXT in the output of 'text_string.sh error_log' instead of using the default error log grep"
  fi
  if [ $FORCE_SKIPV -gt 0 ]; then 
    if [ "$MULTI_REDUCER" != "1" ]; then  # This is the main reducer
      echo_out "[Init] FORCE_SKIPV active. Verify stage skipped, and immediately commencing multi threaded simplification"
    else  # This is a subreducer (i.e. not multi-threaded)
      echo_out "[Init] FORCE_SKIPV active. Verify stage skipped, and immediately commencing simplification"
    fi
  fi
  if [ $FORCE_SKIPV -gt 0 -a $FORCE_SPORADIC -gt 0 ]; then echo_out "[Init] FORCE_SKIPV active, so FORCE_SPORADIC is automatically set active also" ; fi
  if [ $REDUCE_GLIBC_OR_SS_CRASHES -gt 0 ]; then
    if [ $FORCE_SKIPV -gt 0 ]; then 
      echo_out "[Init] REDUCE_GLIBC_OR_SS_CRASHES active, so automatically skipping VERIFY mode as GLIBC crashes may be sporadic more often (this happens irrespective of FORCE_SKIPV=1)"
    else
      echo_out "[Init] REDUCE_GLIBC_OR_SS_CRASHES active, so automatically skipping VERIFY mode as GLIBC crashes may be sporadic more often"
    fi
    echo_out "[Init] REDUCE_GLIBC_OR_SS_CRASHES active, so automatically set SLOW_DOWN_CHUNK_SCALING=1 to slow down chunk size scaling (both for chunk reductions and increases)"
    if [ $FORCE_SPORADIC -gt 0 ]; then
      echo_out "[Info] FORCE_SPORADIC active, issue is assumed to be sporadic"
      echo_out "[Init] FORCE_SPORADIC active: STAGE1_LINES variable was overwritten and set to $STAGE1_LINES to match"
    fi
    if [ $MODE -eq 3 ]; then
      echo_out "[WARNING] ---------------------"
      echo_out "[WARNING] REDUCE_GLIBC_OR_SS_CRASHES active and MODE=3. Have you updated the TEXT=\"...\" to a search string matching the console (on-screen) output of a GLIBC crash instead of using some text from the error log (which is not scanned now)? The output of a GLIBC crash is on the main console stdout, so a copy/paste of a suitable search string may be made directly from the console. A GLIBC crash looks similar to this: *** Error in \`/sda/PS180516-percona-server-5.6.30-76.3-linux-x86_64-debug/bin/mysqld': corrupted double-linked list: 0x00007feb2c0011e0 ***. For the TEXT search string, do not use the hex address but instead, for example, 'corrupted double-linked list', or a specfic frame from the stack trace which is normally shown below this intro line. Note that the message can also look like this (on Ubuntu); *** stack smashing detected ***: /your_basedir/bin/mysqld terminated. The best way to find out what the message is on your system is to run reducer first normally (without REDUCE_GLIBC_OR_SS_CRASHES set, and check what the output is. Alternatively, set MODE=4 to look for any GLIBC crash. If this reducer.sh was generated by pquery-prep-red.sh, then note that TEXT would have been automatically set to content from the error log, or to a more generic MODE=4, but neither of these will reduce for GLIBC crashes (is MODE=3 this is because the error log is not scanned, and in MODE=4 this is because the GLIBC crash (or stack smash) may be offset/different from any crash in the error log). Instead, set the TEXT string to a GLIBC specific string as described."
      echo_out "[WARNING] ---------------------"
    fi       
  else
    if [ $FORCE_SPORADIC -gt 0 ]; then
      if [ $FORCE_SKIPV -gt 0 ]; then
        echo_out "[Init] FORCE_SPORADIC active. Issue is assumed to be sporadic"
      else
        echo_out "[Init] FORCE_SPORADIC active. Issue is assumed to be sporadic, even if verify stage shows otherwise"
      fi
      echo_out "[Init] FORCE_SPORADIC, FORCE_SKIPV and/or PQUERY_MULTI active: STAGE1_LINES variable was overwritten and set to $STAGE1_LINES to match"
    fi
  fi
  if [ $FORCE_SPORADIC -gt 0 ]; then
    echo_out "[Init] FORCE_SPORADIC active, so automatically enabled SLOW_DOWN_CHUNK_SCALING to speed up testcase reduction (SLOW_DOWN_CHUNK_SCALING_NR is set to $SLOW_DOWN_CHUNK_SCALING_NR)"
  fi
  if [ ${REDUCE_STARTUP_ISSUES} -eq 1 ]; then
    echo_out "[Init] REDUCE_STARTUP_ISSUES active. Issue is assumed to be a startup issue"
    echo_out "[Info] Note: REDUCE_STARTUP_ISSUES is normally used for debugging mysqld startup issues only; for example caused by a misbehaving --option to mysqld. You may want to make the SQL input file really small (for example 'SELECT 1;' only) to ensure that when the particular issue being debugged is not seen, reducer will not spent a long time on executing SQL unrelated to the real issue, i.e. failing mysqld startup"
  fi
  if [ $ENABLE_QUERYTIMEOUT -gt 0 ]; then 
    echo_out "[Init] Querytimeout: ${QUERYTIMEOUT}s (For RQG-originating testcase reductions, ensure this is at least 1.5x what was set in RQG using the --querytimeout option)"
  fi
  if [ $PQUERY_MOD -eq 0 ]; then
    if   [ ${CLI_MODE} -eq 0 ]; then echo_out "[Init] Using the mysql client for SQL replay. CLI_MODE: 0 (cat input.sql | mysql)"; 
    elif [ ${CLI_MODE} -eq 1 ]; then echo_out "[Init] Using the mysql client for SQL replay. CLI_MODE: 1 (mysql --execute='SOURCE input.sql')"; 
    elif [ ${CLI_MODE} -eq 2 ]; then echo_out "[Init] Using the mysql client for SQL replay. CLI_MODE: 2 (mysql < input.sql)";
    else echo "Error: CLI_MODE!=0,1,2: CLI_MODE=${CLI_MODE}"; exit 1; fi
  else
    echo_out "[Init] Using the pquery client for SQL replay"
  fi
  if [ -n "$MYEXTRA" ]; then echo_out "[Init] Passing the following additional options to mysqld: $MYEXTRA"; fi
  if [ $MODE -ge 6 ]; then 
    if [ $TS_TRXS_SETS -eq 1 ]; then echo_out "[Init] ThreadSync: using last transaction set (accross threads) only"; fi
    if [ $TS_TRXS_SETS -gt 1 ]; then echo_out "[Init] ThreadSync: using last $TS_TRXS_SETS transaction sets (accross threads) only"; fi
    if [ $TS_TRXS_SETS -eq 0 ]; then echo_out "[Init] ThreadSync: using complete input files (you may want to set TS_DS_TIMEOUT=10 [seconds] or less)"; fi
    if [ $TS_VARIABILITY_SLEEP -gt 0 ]; then echo_out "[Init] ThreadSync: will wait $TS_VARIABILITY_SLEEP seconds before each new transaction set is processed"; fi
    echo_out "[Init] ThreadSync: default DEBUG_SYNC timeout (TS_DS_TIMEOUT): $TS_DS_TIMEOUT seconds"
    if [ $TS_DBG_CLI_OUTPUT -eq 1 ]; then 
      echo_out "[Init] ThreadSync: using debug (-vvv) mysql CLI output logging"
      echo_out "[Warning] ThreadSync: ONLY use -vvv logging for debugging, as this *will* cause issue non-reproducilbity due to excessive disk logging!"
    fi
  fi
  if [ $PXC_MOD -gt 0 ]; then
    echo_out "[Init] PXC_MOD active, so automatically set PQUERY_MOD=1: Percona XtraDB Cluster testcase reduction is currently supported only with pquery"
    if [ $MODE -eq 5 -o $MODE -eq 3 ]; then
      echo_out "[Warning] MODE=$MODE is set, as well as PXC mode active. This combination will likely work, but has not been tested yet. Please remove this warning (for MODE=$MODE only please) when it was tested succesfully"
    fi
    if [ $MODE -eq 4 ]; then
      if [ $PXC_ISSUE_NODE -eq 0 ]; then
        echo_out "[Info] All PXC nodes will be checked for the issue. As long as one node reproduces, testcase reduction will continue (PXC_ISSUE_NODE=0)"
      elif [ $PXC_ISSUE_NODE -eq 1 ]; then
        echo_out "[Info] Important: PXC_ISSUE_NODE is set to 1, so only PXC node 1 will be checked for the presence of the issue"
      elif [ $PXC_ISSUE_NODE -eq 2 ]; then
        echo_out "[Info] Important: PXC_ISSUE_NODE is set to 2, so only PXC node 2 will be checked for the presence of the issue"
      elif [ $PXC_ISSUE_NODE -eq 3 ]; then
        echo_out "[Info] Important: PXC_ISSUE_NODE is set to 3, so only PXC node 3 will be checked for the presence of the issue"
      fi
    fi
  fi
  if [ $GRP_RPL_MOD -gt 0 ]; then
    echo_out "[Init] GRP_RPL_MOD active, so automatically set PQUERY_MOD=1: Group Replication Cluster testcase reduction is currently supported only with pquery"
    if [ $MODE -eq 5 -o $MODE -eq 3 ]; then
      echo_out "[Warning] MODE=$MODE is set, as well as Group Replication mode active. This combination will likely work, but has not been tested yet. Please remove this warning (for MODE=$MODE only please) when it was tested succesfully"
    fi
    if [ $MODE -eq 4 ]; then
      if [ $GRP_RPL_ISSUE_NODE -eq 0 ]; then
        echo_out "[Info] All Group Replication nodes will be checked for the issue. As long as one node reproduces, testcase reduction will continue (GRP_RPL_ISSUE_NODE=0)"
      elif [ $GRP_RPL_ISSUE_NODE -eq 1 ]; then
        echo_out "[Info] Important: GRP_RPL_ISSUE_NODE is set to 1, so only PXC node 1 will be checked for the presence of the issue"
      elif [ $GRP_RPL_ISSUE_NODE -eq 2 ]; then
        echo_out "[Info] Important: GRP_RPL_ISSUE_NODE is set to 2, so only PXC node 2 will be checked for the presence of the issue"
      elif [ $GRP_RPL_ISSUE_NODE -eq 3 ]; then
        echo_out "[Info] Important: GRP_RPL_ISSUE_NODE is set to 3, so only PXC node 3 will be checked for the presence of the issue"
      fi
    fi
  fi
  if [ "$MULTI_REDUCER" != "1" ]; then  # This is a parent/main reducer
    if [[ $PXC_MOD -ne 1 && $GRP_RPL_MOD -ne 1 ]]; then 
      echo_out "[Init] Setting up standard working template (without using MYEXTRA options)"
      # Get version specific options
      MID=
      if [ -r ${BASEDIR}/scripts/mysql_install_db ]; then MID="${BASEDIR}/scripts/mysql_install_db"; fi
      if [ -r ${BASEDIR}/bin/mysql_install_db ]; then MID="${BASEDIR}/bin/mysql_install_db"; fi
      START_OPT="--core-file"           # Compatible with 5.6,5.7,8.0
      INIT_OPT="--initialize-insecure"  # Compatible with     5.7,8.0 (mysqld init)
      INIT_TOOL="${BIN}"                # Compatible with     5.7,8.0 (mysqld init), changed to MID later if version <=5.6
      VERSION_INFO=$(${BIN} --version | grep -E -oe '[58]\.[01567]' | head -n1)
      if [ "${VERSION_INFO}" == "5.1" -o "${VERSION_INFO}" == "5.5" -o "${VERSION_INFO}" == "5.6" ]; then
        if [ "${MID}" == "" ]; then
          echo "Assert: Version was detected as ${VERSION_INFO}, yet ./scripts/mysql_install_db nor ./bin/mysql_install_db is present!"
          exit 1
        fi
        INIT_TOOL="${MID}"
        INIT_OPT="--force --no-defaults"
        START_OPT="--core"
      elif [ "${VERSION_INFO}" != "5.7" -a "${VERSION_INFO}" != "8.0" ]; then
        echo "WARNING: mysqld (${BIN}) version detection failed. This is likely caused by using this script with a non-supported distribution or version of mysqld. Please expand this script to handle (which shoud be easy to do). Even so, the scipt will now try and continue as-is, but this may fail."
      fi
      generate_run_scripts
      ${INIT_TOOL} ${INIT_OPT} --basedir=$BASEDIR --datadir=$WORKD/data ${MID_OPTIONS} --user=$MYUSER > $WORKD/init.log 2>&1
      # test db provisioning if not there already (needs to be done here & not earlier as mysql_install_db expects an empty data directory in 5.7)
      mkdir $WORKD/data/test 2>/dev/null  
      if [ ! -d $WORKD/data ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [ERROR] data directory at $WORKD/data does not exist... check $WORKD/error.log.out, $WORKD/mysqld.out and $WORKD/init.log"
        echo "Terminating now."
        exit 1
      else
        # Note that 'mv data data.init' needs to come BEFORE first mysqld startup attempt, to not pollute the template with an actual mysqld startup (think --init-file and tokudb)
        mv ${WORKD}/data ${WORKD}/data.init
        cp -a ${WORKD}/data.init ${WORKD}/data  # We need this for the first mysqld startup attempt just below
      fi
      #start_mysqld_main
      echo_out "[Init] Attempting first mysqld startup with all MYEXTRA options passed to mysqld"
      if [ $MODE -ne 1 -a $MODE -ne 6 ]; then start_mysqld_main; else start_valgrind_mysqld_main; fi
      if ! $BASEDIR/bin/mysqladmin -uroot -S$WORKD/socket.sock ping > /dev/null 2>&1; then 
        if [ ${REDUCE_STARTUP_ISSUES} -eq 1 ]; then 
          echo_out "[Init] [NOTE] Failed to cleanly start mysqld server (This was the 1st startup attempt with all MYEXTRA options passed to mysqld). Normally this would cause reducer.sh to halt here (and advice you to check $WORKD/error.log.out, $WORKD/mysqld.out, $WORKD/init.log, and maybe $WORKD/data/error.log + check that there is plenty of space on the device being used). However, because REDUCE_STARTUP_ISSUES is set to 1, we continue this reducer run. See above for more info on the REDUCE_STARTUP_ISSUES setting"
        else
          echo_out "[Init] [ERROR] Failed to start mysqld server (This was the 1st startup attempt with all MYEXTRA options passed to mysqld), check $WORKD/error.log.out, $WORKD/mysqld.out, $WORKD/init.log, and maybe $WORKD/data/error.log. Also check that there is plenty of space on the device being used"
          echo_out "[Init] [INFO] If however you want to debug a mysqld startup issue, for example caused by a misbehaving --option to mysqld, set REDUCE_STARTUP_ISSUES=1 and restart reducer.sh"
          echo "Terminating now."
          exit 1
        fi
      fi
      if [ $LOAD_TIMEZONE_DATA -gt 0 ]; then
        echo_out "[Init] Loading timezone data into mysql database"
        # echo_out "[Info] You may safely ignore any 'Warning: Unable to load...' messages, unless there are very many (Ref. BUG#13563952)"
        # The ones listed in BUG#13563952 are now filterered out to make output nicer
        $BASEDIR/bin/mysql_tzinfo_to_sql /usr/share/zoneinfo > $WORKD/timezone.init 2> $WORKD/timezone.err
        grep -E --binary-files=text -v "Riyadh8[789]'|zoneinfo/iso3166.tab|zoneinfo/zone.tab" $WORKD/timezone.err > $WORKD/timezone.err.tmp 
        for A in $(cat $WORKD/timezone.err.tmp|sed 's/ /=DUMMY=/g'); do 
          echo_out "$(echo "[Warning from mysql_tzinfo_to_sql] $A" | sed 's/=DUMMY=/ /g')"
        done
        echo_out "[Info] If you see a [GLIBC] crash above, change reducer to use a non-Valgrind-instrumented build of mysql_tzinfo_to_sql (Ref. BUG#13498842)"
        $BASEDIR/bin/mysql -uroot -S$WORKD/socket.sock --force mysql < $WORKD/timezone.init
      fi
      stop_mysqld_or_pxc
    elif [[ $PXC_MOD -eq 1 ]]; then
      echo_out "[Init] Setting up standard PXC working template (without using MYEXTRA options)"
      if [ "$(${BASEDIR}/bin/mysqld --version | grep -E -oe '5\.[567]' | head -n1)" == "5.7" ]; then
        MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
      elif [ "$(${BASEDIR}/bin/mysqld --version | grep -E -oe '5\.[567]' | head -n1)" == "5.6" ]; then
        MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
      fi
      node1="${WORKD}/node1"
      node2="${WORKD}/node2"
      node3="${WORKD}/node3"
      if [ "$(${BASEDIR}/bin/mysqld --version | grep -E -oe '5\.[567]' | head -n1)" != "5.7" ]; then
        mkdir -p $node1 $node2 $node3
      fi
      ${MID} --datadir=$node1  > ${WORKD}/startup_node1_error.log 2>&1 || exit 1;
      ${MID} --datadir=$node2  > ${WORKD}/startup_node2_error.log 2>&1 || exit 1;
      ${MID} --datadir=$node3  > ${WORKD}/startup_node3_error.log 2>&1 || exit 1;
      mkdir $WORKD/node1.init $WORKD/node2.init $WORKD/node3.init
      cp -a $WORKD/node1/* $WORKD/node1.init/
      cp -a $WORKD/node2/* $WORKD/node2.init/
      cp -a $WORKD/node3/* $WORKD/node3.init/
    elif [[ $GRP_RPL_MOD -eq 1 ]]; then
      echo_out "[Init] Setting up standard Group Replication working template (without using MYEXTRA options)"
      MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
      node1="${WORKD}/node1"
      node2="${WORKD}/node2"
      node3="${WORKD}/node3"
      ${MID} --datadir=$node1  > ${WORKD}/startup_node1_error.log 2>&1 || exit 1;
      ${MID} --datadir=$node2  > ${WORKD}/startup_node2_error.log 2>&1 || exit 1;
      ${MID} --datadir=$node3  > ${WORKD}/startup_node3_error.log 2>&1 || exit 1;
      mkdir $WORKD/node1.init $WORKD/node2.init $WORKD/node3.init
      cp -a $WORKD/node1/* $WORKD/node1.init/
      cp -a $WORKD/node2/* $WORKD/node2.init/
      cp -a $WORKD/node3/* $WORKD/node3.init/
    fi
  else
    echo_out "[Init] This is a subreducer process; using initialization data template from the main process ($WORKD/../../data.init)"
  fi
}

generate_run_scripts(){
  # Add various scripts (with {epoch} prefix): _mybase (setup variables), _init (setup), _run (runs the sql), _cl (starts a mysql cli), _stop (stop mysqld). _start (starts mysqld)
  # (start_mysqld_main and start_valgrind_mysqld_main). Togheter these scripts can be used for executing the final testcase ($WORKO_start > $WORKO_run)
  echo "BASEDIR=$BASEDIR" | sed 's|^[ \t]*||;s|[ \t]*$||;s|/$||' > $WORK_BASEDIR
  echo "SOURCE_DIR=\$BASEDIR  # Only required to be set if make_binary_distrubtion script was NOT used to build MySQL" | sed 's|^[ \t]*||;s|[ \t]*$||;s|/$||' >> $WORK_BASEDIR
  echo "JEMALLOC=~/libjemalloc.so.1  # Only required for Percona Server with TokuDB. Can be completely ignored otherwise. This can be changed to a custom path to use a custom jemalloc. If this file is not present, the standard OS locations for jemalloc will be checked" >> $WORK_BASEDIR
  echo "SCRIPT_DIR=\$(cd \$(dirname \$0) && pwd)" > $WORK_INIT
  echo "source \$SCRIPT_DIR/${EPOCH}_mybase" >> $WORK_INIT
  echo "echo \"Attempting to prepare mysqld environment at /dev/shm/${EPOCH}...\"" >> $WORK_INIT
  echo "rm -Rf /dev/shm/${EPOCH}" >> $WORK_INIT
  echo "mkdir -p /dev/shm/${EPOCH}/tmp" >> $WORK_INIT
  echo "BIN=\`find \${BASEDIR} -maxdepth 2 -name mysqld -type f -o -name mysqld-debug -type f | head -1\`" >> $WORK_INIT
  echo "if [ -n \"\$BIN\"  ]; then" >> $WORK_INIT
  echo "  if [ \"\$BIN\" != \"\${BASEDIR}/bin/mysqld\" -a \"\$BIN\" != \"\${BASEDIR}/bin/mysqld-debug\" ];then" >> $WORK_INIT
  echo "    if [ ! -h \${BASEDIR}/bin/mysqld -o ! -f \${BASEDIR}/bin/mysqld ]; then mkdir -p \${BASEDIR}/bin; ln -s \$BIN \${BASEDIR}/bin/mysqld; fi" >> $WORK_INIT
  echo "    if [ ! -h \${BASEDIR}/bin/mysql -o ! -f \${BASEDIR}/bin/mysql ]; then ln -s \${BASEDIR}/client/mysql \${BASEDIR}/bin/mysql ; fi" >> $WORK_INIT
  echo "    if [ ! -h \${BASEDIR}/share -o ! -f \${BASEDIR}/share ]; then ln -s \${SOURCE_DIR}/scripts \${BASEDIR}/share ; fi" >> $WORK_INIT
  echo -e "    if [ ! -h \${BASEDIR}/share/errmsg.sys -o ! -f \${BASEDIR}/share/errmsg.sys ]; then ln -s \${BASEDIR}/sql/share/english/errmsg.sys \${BASEDIR}/share/errmsg.sys ; fi;\n  fi\nelse" >> $WORK_INIT
  echo -e "  echo \"Assert! mysqld binary '\$BIN' could not be read\";exit 1;\nfi" >> $WORK_INIT
  echo "MID=\`find \${BASEDIR} -maxdepth 2 -name mysql_install_db\`;if [ -z "\$MID" ]; then echo \"Assert! mysql_install_db '\$MID' could not be read\";exit 1;fi" >> $WORK_INIT
  echo "if [ \"\`\$BIN --version | grep -E -oe '5\.[1567]' | head -n1\`\" == \"5.7\" ]; then MID_OPTIONS='--initialize-insecure'; elif [ \"\`\$BIN --version | grep -E -oe '5\.[1567]' | head -n1\`\" == \"5.6\" ]; then MID_OPTIONS='--force'; elif [ \"\`\$BIN --version| grep -E -oe '5\.[1567]' | head -n1\`\" == \"5.5\" ]; then MID_OPTIONS='--force';else MID_OPTIONS=''; fi" >> $WORK_INIT
  echo "if [ \"\`\$BIN --version | grep -E -oe '5\.[1567]' | head -n1\`\" == \"5.7\" ]; then \$BIN  --no-defaults --basedir=\${BASEDIR} --datadir=/dev/shm/${EPOCH}/data \$MID_OPTIONS; else \$MID --no-defaults --basedir=\${BASEDIR} --datadir=/dev/shm/${EPOCH}/data \$MID_OPTIONS; fi" >> $WORK_INIT
  echo "mkdir -p /dev/shm/${EPOCH}/data/test" >> $WORK_INIT
  if [ $MODE -ge 6 ]; then
    # This still needs implementation for MODE6 or higher ("else line" below simply assumes a single $WORKO atm, while MODE6 and higher has more then 1)
    echo_out "[Not implemented yet] MODE6 or higher does not auto-generate a $WORK_RUN file yet"
    echo "Not implemented yet: MODE6 or higher does not auto-generate a $WORK_RUN file yet" > $WORK_RUN
    echo "#${BASEDIR}/bin/mysql -uroot -S/dev/shm/${EPOCH}/socket.sock < INPUT_FILE_GOES_HERE (like $WORKO)" >> $WORK_RUN
    chmod +x $WORK_RUN
  else
    echo "SCRIPT_DIR=\$(cd \$(dirname \$0) && pwd)" > $WORK_RUN
    echo "source \$SCRIPT_DIR/${EPOCH}_mybase" >> $WORK_RUN
    echo "echo \"Executing testcase ./${EPOCH}.sql against mysqld with socket /dev/shm/${EPOCH}/socket.sock using the mysql CLI client...\"" >> $WORK_RUN
    if [ "$CLI_MODE" == "" ]; then CLI_MODE=99; fi  # Leads to assert below
    case $CLI_MODE in
      0) echo "cat ./${EPOCH}.sql | \${BASEDIR}/bin/mysql -uroot -S/dev/shm/${EPOCH}/socket.sock --binary-mode --force test" >> $WORK_RUN ;;
      1) echo "\${BASEDIR}/bin/mysql -uroot -S/dev/shm/${EPOCH}/socket.sock --execute=\"SOURCE ./${EPOCH}.sql;\" --force test" >> $WORK_RUN ;;  # When http://bugs.mysql.com/bug.php?id=81782 is fixed, re-add --binary-mode to this command. Also note that due to http://bugs.mysql.com/bug.php?id=81784, the --force option has to be after the --execute option.
      2) echo "\${BASEDIR}/bin/mysql -uroot -S/dev/shm/${EPOCH}/socket.sock --binary-mode --force test < ./${EPOCH}.sql" >> $WORK_RUN ;;
      *) echo_out "Assert: default clause in CLI_MODE switchcase hit (in generate_run_scripts). This should not happen. CLI_MODE=${CLI_MODE}"; exit 1 ;;
    esac
    chmod +x $WORK_RUN
    if [ $PQUERY_MOD -eq 1 ]; then
      cp $PQUERY_LOC $WORK_PQUERY_BIN  # Make a copy of the pquery binary for easy replay later (no need to download)
      if [[ $PXC_MOD -eq 1 || $GRP_RPL_MOD -eq 1 ]]; then
        echo "echo \"Executing testcase ./${EPOCH}.sql against mysqld at 127.0.0.1:10000 using pquery...\"" > $WORK_RUN_PQUERY
        echo "SCRIPT_DIR=\$(cd \$(dirname \$0) && pwd)" >> $WORK_RUN_PQUERY
        echo "source \$SCRIPT_DIR/${EPOCH}_mybase" >> $WORK_RUN_PQUERY
        echo "export LD_LIBRARY_PATH=\${BASEDIR}/lib" >> $WORK_RUN_PQUERY
        if [ $PQUERY_MULTI -eq 1 ]; then
          if [ $PQUERY_REVERSE_NOSHUFFLE_OPT -ge 1 ]; then PQUERY_SHUFFLE="--no-shuffle"; else PQUERY_SHUFFLE=""; fi
          echo "$(echo $PQUERY_LOC | sed "s|.*/|./${EPOCH}_|") --infile=./${EPOCH}.sql --database=test $PQUERY_SHUFFLE --threads=$PQUERY_MULTI_CLIENT_THREADS --queries=$PQUERY_MULTI_QUERIES --user=root --socket=/dev/shm/${EPOCH}/node1/node1_socket.sock --log-all-queries --log-failed-queries $PQUERY_EXTRA_OPTIONS" >> $WORK_RUN_PQUERY
        else
          if [ $PQUERY_REVERSE_NOSHUFFLE_OPT -ge 1 ]; then PQUERY_SHUFFLE=""; else PQUERY_SHUFFLE="--no-shuffle"; fi
          echo "$(echo $PQUERY_LOC | sed "s|.*/|./${EPOCH}_|") --infile=./${EPOCH}.sql --database=test $PQUERY_SHUFFLE --threads=1 --user=root --socket=/dev/shm/${EPOCH}/node1/node1_socket.sock --log-all-queries --log-failed-queries $PQUERY_EXTRA_OPTIONS" >> $WORK_RUN_PQUERY
        fi
      else
        echo "echo \"Executing testcase ./${EPOCH}.sql against mysqld with socket /dev/shm/${EPOCH}/socket.sock using pquery...\"" > $WORK_RUN_PQUERY
        echo "SCRIPT_DIR=\$(cd \$(dirname \$0) && pwd)" >> $WORK_RUN_PQUERY
        echo "source \$SCRIPT_DIR/${EPOCH}_mybase" >> $WORK_RUN_PQUERY
        echo "export LD_LIBRARY_PATH=\${BASEDIR}/lib" >> $WORK_RUN_PQUERY
        if [ $PQUERY_MULTI -eq 1 ]; then
          if [ $PQUERY_REVERSE_NOSHUFFLE_OPT -ge 1 ]; then PQUERY_SHUFFLE="--no-shuffle"; else PQUERY_SHUFFLE=""; fi
          echo "$(echo $PQUERY_LOC | sed "s|.*/|./${EPOCH}_|") --infile=./${EPOCH}.sql --database=test $PQUERY_SHUFFLE --threads=$PQUERY_MULTI_CLIENT_THREADS --queries=$PQUERY_MULTI_QUERIES --user=root --socket=/dev/shm/${EPOCH}/socket.sock --logdir=$WORKD --log-all-queries --log-failed-queries $PQUERY_EXTRA_OPTIONS" >> $WORK_RUN_PQUERY
        else
          if [ $PQUERY_REVERSE_NOSHUFFLE_OPT -ge 1 ]; then PQUERY_SHUFFLE=""; else PQUERY_SHUFFLE="--no-shuffle"; fi
          echo "$(echo $PQUERY_LOC | sed "s|.*/|./${EPOCH}_|") --infile=./${EPOCH}.sql --database=test $PQUERY_SHUFFLE --threads=1 --user=root --socket=/dev/shm/${EPOCH}/socket.sock --logdir=$WORKD --log-all-queries --log-failed-queries $PQUERY_EXTRA_OPTIONS" >> $WORK_RUN_PQUERY
        fi
      fi
      chmod +x $WORK_RUN_PQUERY
    fi
  fi 
  echo "SCRIPT_DIR=\$(cd \$(dirname \$0) && pwd)" > $WORK_GDB
  echo "source \$SCRIPT_DIR/${EPOCH}_mybase" >> $WORK_GDB
  echo "gdb \${BASEDIR}/bin/mysqld \$(ls /dev/shm/${EPOCH}/data/core.*)" >> $WORK_GDB
  echo "SCRIPT_DIR=\$(cd \$(dirname \$0) && pwd)" > $WORK_PARSE_CORE
  echo "source \$SCRIPT_DIR/${EPOCH}_mybase" >> $WORK_PARSE_CORE
  echo "gdb \${BASEDIR}/bin/mysqld \$(ls /dev/shm/${EPOCH}/data/core.*) >/dev/null 2>&1 <<EOF" >> $WORK_PARSE_CORE
  echo -e "  set auto-load safe-path /\n  set libthread-db-search-path /usr/lib/\n  set trace-commands on\n  set pagination off\n  set print pretty on\n  set print array on\n  set print array-indexes on\n  set print elements 4096\n  set logging file ${EPOCH}_FULL.gdb\n  set logging on\n  thread apply all bt full\n  set logging off\n  set logging file ${EPOCH}_STD.gdb\n  set logging on\n  thread apply all bt\n  set logging off\n  quit\nEOF" >> $WORK_PARSE_CORE
  echo "SCRIPT_DIR=\$(cd \$(dirname \$0) && pwd)" > $WORK_STOP
  echo "source \$SCRIPT_DIR/${EPOCH}_mybase" >> $WORK_STOP
  echo "echo \"Attempting to shutdown mysqld with socket /dev/shm/${EPOCH}/socket.sock...\"" >> $WORK_STOP
  echo "MYADMIN=\`find \${BASEDIR} -maxdepth 2 -type f -name mysqladmin\`" >> $WORK_STOP
  echo "\$MYADMIN -uroot -S/dev/shm/${EPOCH}/socket.sock shutdown" >> $WORK_STOP
  echo "SCRIPT_DIR=\$(cd \$(dirname \$0) && pwd)" > $WORK_CL
  echo "source \$SCRIPT_DIR/${EPOCH}_mybase" >> $WORK_CL
  echo "echo \"Connecting to mysqld with socket -S/dev/shm/${EPOCH}/socket.sock test using the mysql CLI client...\"" >> $WORK_CL
  echo "\${BASEDIR}/bin/mysql -uroot -S/dev/shm/${EPOCH}/socket.sock test" >> $WORK_CL
  echo -e "The attached tarball (${EPOCH}_bug_bundle.tar.gz) gives the testcase as an exact match of our system, including some handy utilities\n" > $WORK_HOW_TO_USE
  echo "$ vi ${EPOCH}_mybase         # STEP1: Update the base path in this file (usually the only change required!). If you use a non-binary distribution, please update SOURCE_DIR location also" >> $WORK_HOW_TO_USE
  echo "$ ./${EPOCH}_init            # STEP2: Initializes the data dir" >> $WORK_HOW_TO_USE
  if [ $MODE -eq 1 -o $MODE -eq 6 ]; then
    echo "$ ./${EPOCH}_start_valgrind  # STEP3: Starts mysqld under Valgrind (make sure to use a Valgrind instrumented build) (note: this can easily take 20-30 seconds or more)" >> $WORK_HOW_TO_USE
  else
    echo "$ ./${EPOCH}_start           # STEP3: Starts mysqld" >> $WORK_HOW_TO_USE
  fi
  echo "$ ./${EPOCH}_cl              # STEP4: To check mysqld is up" >> $WORK_HOW_TO_USE
  if [ $PQUERY_MOD -eq 1 ]; then
    echo "$ ./${EPOCH}_run_pquery      # STEP5: Run the testcase with the pquery binary" >> $WORK_HOW_TO_USE
    echo "$ ./${EPOCH}_run             # OPTIONAL: Run the testcase with the mysql CLI (may not reproduce the issue, as the pquery binary was used for the original testcase reduction)" >> $WORK_HOW_TO_USE
    if [ $MODE -eq 1 -o $MODE -eq 6 ]; then
      echo "$ ./${EPOCH}_stop            # STEP6: Stop mysqld (and wait for Valgrind to write end-of-Valgrind-run details to the mysqld error log)" >> $WORK_HOW_TO_USE
    fi
  else
    echo "$ ./${EPOCH}_run             # STEP5: Run the testcase with the mysql CLI" >> $WORK_HOW_TO_USE
    if [ $MODE -eq 1 -o $MODE -eq 6 ]; then
      echo "$ ./${EPOCH}_stop            # STEP6: Stop mysqld (and wait for Valgrind to write end-of-Valgrind-run details to the mysqld error log)" >> $WORK_HOW_TO_USE
    fi
  fi
  if [ $MODE -eq 1 -o $MODE -eq 6 ]; then
    echo "$ vi /dev/shm/${EPOCH}/error.log.out  # STEP7: Verify the error log" >> $WORK_HOW_TO_USE
  else
    echo "$ vi /dev/shm/${EPOCH}/error.log.out  # STEP6: Verify the error log" >> $WORK_HOW_TO_USE
  fi
  echo "$ ./${EPOCH}_gdb             # OPTIONAL: Brings you to a gdb prompt with gdb attached to the used mysqld and attached to the generated core" >> $WORK_HOW_TO_USE
  echo "$ ./${EPOCH}_parse_core      # OPTIONAL: Creates ${EPOCH}_STD.gdb and ${EPOCH}_FULL.gdb; standard and full variables gdb stack traces" >> $WORK_HOW_TO_USE
  chmod +x $WORK_CL $WORK_STOP $WORK_GDB $WORK_PARSE_CORE $WORK_INIT
}

init_mysql_dir(){
  if [[ $PXC_MOD -eq 1 || $GRP_RPL_MOD -eq 1 ]]; then
    sudo rm -Rf $WORKD/node1 $WORKD/node2 $WORKD/node3
    cp -a ${node1}.init ${node1}
    cp -a ${node2}.init ${node2}
    cp -a ${node3}.init ${node3}
  else
    rm -Rf $WORKD/data/*  $WORKD/tmp/*
    rm -Rf $WORKD/data/.rocksdb 2> /dev/null
    if [ "$MULTI_REDUCER" != "1" ]; then  # This is a parent/main reducer
      cp -a $WORKD/data.init/* $WORKD/data/
    else
      cp -a $WORKD/../../data.init/* $WORKD/data/
    fi
  fi
  if [ $REDUCE_GLIBC_OR_SS_CRASHES -gt 0 ]; then
    echo "" > /tmp/reducer_typescript${TYPESCRIPT_UNIQUE_FILESUFFIX}.log
  fi
}

start_mysqld_or_valgrind_or_pxc(){
  init_mysql_dir
  if [ $PXC_MOD -eq 1 ]; then
    start_pxc_main
  elif [ $GRP_RPL_MOD -eq 1 ]; then
    gr_start_main
  else
    # Pre-start cleanup
    if [ -f $WORKD/error.log.out ]; then mv -f $WORKD/error.log.out $WORKD/error.log.prev; fi                    # mysqld error log
    if [ -f $WORKD/mysqld.out ]; then mv -f $WORKD/mysqld.out $WORKD/mysqld.prev; fi                             # mysqld stdout & stderr output, as well as some mysqladmin output
    if [ -f $WORKD/mysql.out ]; then mv -f $WORKD/mysql.out $WORKD/mysql.prev; fi                                # mysql client output
    if [ -f $WORKD/default.node.tld_thread-0.out ]; then mv -f $WORKD/default.node.tld_thread-0.out $WORKD/default.node.tld_thread-0.prev; fi  # pquery client output
    if [ -f $WORKD/default.node.tld_thread-0.sql ]; then mv -f $WORKD/default.node.tld_thread-0.sql $WORKD/default.node.tld_thread-0.prevsql; fi
    # Start
    if [ $MODE -ne 1 -a $MODE -ne 6 ]; then 
      start_mysqld_main
    else 
      start_valgrind_mysqld_main
    fi
    STAGE9_NOT_STARTED_CORRECTLY=0  # Defensive coding only, not strictly required
    if [ ${REDUCE_STARTUP_ISSUES} -le 0 ]; then
      if ! $BASEDIR/bin/mysqladmin -uroot -S$WORKD/socket.sock ping > /dev/null 2>&1; then 
        if [ ${STAGE} -eq 9 ]; then
          STAGE9_NOT_STARTED_CORRECTLY=1
          echo_out "$ATLEASTONCE [Stage $STAGE] [ERROR] Failed to start mysqld server, assuming this engine is required"
        else
          echo_out "$ATLEASTONCE [Stage $STAGE] [ERROR] Failed to start mysqld server, check $WORKD/error.log.out, $WORKD/mysqld.out and $WORKD/init.log"
          echo "Terminating now."
          exit 1
        fi
      fi
    fi
  fi
  STARTUPCOUNT=$[$STARTUPCOUNT+1]
}

start_pxc_main(){
  ADDR="127.0.0.1"
  RPORT=$(( RANDOM%21 + 10 ))
  RBASE1="$(( RPORT*1000 ))"
  RADDR1="$ADDR:$(( RBASE1 + 7 ))"
  LADDR1="$ADDR:$(( RBASE1 + 8 ))"
  
  RBASE2="$(( RBASE1 + 100 ))"
  RADDR2="$ADDR:$(( RBASE2 + 7 ))"
  LADDR2="$ADDR:$(( RBASE2 + 8 ))"
  
  RBASE3="$(( RBASE1 + 200 ))"
  RADDR3="$ADDR:$(( RBASE3 + 7 ))"
  LADDR3="$ADDR:$(( RBASE3 + 8 ))"
  
  SUSER=root
  SPASS=

  ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.1 \
    --basedir=${BASEDIR} --datadir=$node1 \
    --loose-debug-sync-timeout=600 --skip-performance-schema \
    --innodb_file_per_table $MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
    --wsrep_cluster_address=gcomm:// \
    --wsrep_node_incoming_address=$ADDR \
    --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1;$WSREP_PROVIDER_OPTIONS" \
    --wsrep_sst_method=rsync --wsrep_sst_auth=$SUSER:$SPASS \
    --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
    --core-file --loose-new --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=$node1/error.log \
    --socket=$node1/node1_socket.sock --log-output=none \
    --port=$RBASE1 --server-id=1 --wsrep_slave_threads=2 > $node1/error.log 2>&1 &

  echo_out "Waiting for node-1 to start ....."
  MPID="$!"
  while true ; do
    sleep 10
    if grep -E --binary-files=text -qi "Synchronized with group, ready for connections" $node1/error.log ; then
     break
    fi
    if [ "${MPID}" == "" ]; then
      echo "Error! server not started.. Terminating!"
      grep -E --binary-files=text -i "ERROR|ASSERTION" $node1/error.log
      echo "Terminating now."
      exit 1
    fi
  done
  sleep 10 

  ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
    --basedir=${BASEDIR} --datadir=$node2 \
    --loose-debug-sync-timeout=600 --skip-performance-schema \
    --innodb_file_per_table $MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
    --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR3 \
    --wsrep_node_incoming_address=$ADDR \
    --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR2;$WSREP_PROVIDER_OPTIONS" \
    --wsrep_sst_method=rsync --wsrep_sst_auth=$SUSER:$SPASS \
    --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
    --core-file --loose-new --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=$node2/error.log \
    --socket=$node2/node2_socket.sock --log-output=none \
    --port=$RBASE2 --server-id=2 --wsrep_slave_threads=2 > $node2/error.log 2>&1 &

  echo_out "Waiting for node-2 to start ....."
  MPID="$!"
  while true ; do
    sleep 10
    if grep -E --binary-files=text -qi "Synchronized with group, ready for connections" $node2/error.log ; then
     break
    fi
    if [ "${MPID}" == "" ]; then
      echo "Error! server not started.. Terminating!"
      grep -E --binary-files=text -i "ERROR|ASSERTION" $node2/error.log
      echo "Terminating now."
      exit 1
    fi
  done
  sleep 10

  ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.3 \
    --basedir=${BASEDIR} --datadir=$node3 \
    --loose-debug-sync-timeout=600 --skip-performance-schema \
    --innodb_file_per_table $MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
    --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2 \
    --wsrep_node_incoming_address=$ADDR \
    --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR3;$WSREP_PROVIDER_OPTIONS" \
    --wsrep_sst_method=rsync --wsrep_sst_auth=$SUSER:$SPASS \
    --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
    --core-file --loose-new --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=$node3/error.log \
    --socket=$node3/node3_socket.sock --log-output=none \
    --port=$RBASE3 --server-id=3 --wsrep_slave_threads=2 > $node3/error.log 2>&1 &

  # ensure that node-3 has started and has joined the group post SST
  echo_out "Waiting for node-3 to start ....."
  MPID="$!"
  while true ; do
    sleep 10
    if grep -E --binary-files=text -qi "Synchronized with group, ready for connections" $node3/error.log ; then
     ${BASEDIR}/bin/mysql -uroot -S$node1/node1_socket.sock -e "create database if not exists test" > /dev/null 2>&1
     break
    fi
    if [ "${MPID}" == "" ]; then
      echo_out "Error! server not started.. Terminating!"
      grep -E --binary-files=text -i "ERROR|ASSERTION" $node3/error.log
      echo "Terminating now."
      exit 1
    fi
  done

  CLUSTER_UP=0
  if $BASEDIR/bin/mysqladmin -uroot --socket=${node3}/node3_socket.sock ping > /dev/null 2>&1; then
    if [ `$BASEDIR/bin/mysql -uroot --socket=${node1}/node1_socket.sock -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep -E "wsrep_cluster" | awk '{print $2}'` -eq 3 ]; then CLUSTER_UP=$[ $CLUSTER_UP + 1]; fi
    if [ `$BASEDIR/bin/mysql -uroot --socket=${node2}/node2_socket.sock -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep -E "wsrep_cluster" | awk '{print $2}'` -eq 3 ]; then CLUSTER_UP=$[ $CLUSTER_UP + 1]; fi
    if [ `$BASEDIR/bin/mysql -uroot --socket=${node3}/node3_socket.sock -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep -E "wsrep_cluster" | awk '{print $2}'` -eq 3 ]; then CLUSTER_UP=$[ $CLUSTER_UP + 1]; fi
    if [ "`$BASEDIR/bin/mysql -uroot --socket=${node1}/node1_socket.sock -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep -E "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ $CLUSTER_UP + 1]; fi
    if [ "`$BASEDIR/bin/mysql -uroot --socket=${node2}/node2_socket.sock -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep -E "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ $CLUSTER_UP + 1]; fi
    if [ "`$BASEDIR/bin/mysql -uroot --socket=${node3}/node3_socket.sock -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep -E "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ $CLUSTER_UP + 1]; fi
  fi
}

gr_start_main(){
  ADDR="127.0.0.1"
  RPORT=$(( RANDOM%21 + 10 ))
  RBASE="$(( RPORT*1000 ))"
  RBASE1="$(( RBASE + 1 ))"
  RBASE2="$(( RBASE + 2 ))"
  RBASE3="$(( RBASE + 3 ))"
  LADDR1="$ADDR:$(( RBASE + 101 ))"
  LADDR2="$ADDR:$(( RBASE + 102 ))"
  LADDR3="$ADDR:$(( RBASE + 103 ))"

  gr_startup_chk(){
    ERROR_LOG=$1
    if grep -E -qi "ERROR. Aborting" $ERROR_LOG ; then
      if grep -E -qi "TCP.IP port. Address already in use" $ERROR_LOG ; then
        echo "Assert! The text '[ERROR] Aborting' was found in the error log due to a IP port conflict (the port was already in use)"
      else
        echo "Assert! '[ERROR] Aborting' was found in the error log. This is likely an issue with one of the \$MYEXTRA (${MYEXTRA}) startup options. Saving trial for further analysis, and dumping error log here for quick analysis. Please check the output against these variables settings."
        grep -E "ERROR" $ERROR_LOG
        exit 1
      fi
    fi
  }

  ${BASEDIR}/bin/mysqld --no-defaults \
    --basedir=${BASEDIR} --datadir=$node1 \
    --innodb_file_per_table $MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --server_id=1 --gtid_mode=ON --enforce_gtid_consistency=ON \
    --master_info_repository=TABLE --relay_log_info_repository=TABLE \
    --binlog_checksum=NONE --log_slave_updates=ON --log_bin=binlog \
    --binlog_format=ROW --innodb_flush_method=O_DIRECT \
    --core-file --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=$node1/error.log \
    --socket=$node1/node1_socket.sock --log-output=none \
    --port=$RBASE1 --transaction_write_set_extraction=XXHASH64 \
    --loose-group_replication_group_name="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
    --loose-group_replication_start_on_boot=off --loose-group_replication_local_address="$LADDR1" \
    --loose-group_replication_group_seeds="$LADDR1,$LADDR2,$LADDR3" \
    --loose-group_replication_bootstrap_group=off --super_read_only=OFF > $node1/node1.err 2>&1 &

  for X in $(seq 0 200); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$node1/node1_socket.sock ping > /dev/null 2>&1; then
      sleep 2
      ${BASEDIR}/bin/mysql -uroot -S$node1/node1_socket.sock -Bse "create database if not exists test" > /dev/null 2>&1
      ${BASEDIR}/bin/mysql -uroot -S$node1/node1_socket.sock -Bse "SET SQL_LOG_BIN=0;CREATE USER rpl_user@'%';GRANT REPLICATION SLAVE ON *.* TO rpl_user@'%' IDENTIFIED BY 'rpl_pass';FLUSH PRIVILEGES;SET SQL_LOG_BIN=1;" > /dev/null 2>&1
      ${BASEDIR}/bin/mysql -uroot -S$node1/node1_socket.sock -Bse "CHANGE MASTER TO MASTER_USER='rpl_user', MASTER_PASSWORD='rpl_pass' FOR CHANNEL 'group_replication_recovery';" > /dev/null 2>&1
      ${BASEDIR}/bin/mysql -uroot -S$node1/node1_socket.sock -Bse "INSTALL PLUGIN group_replication SONAME 'group_replication.so';SET GLOBAL group_replication_bootstrap_group=ON;START GROUP_REPLICATION;SET GLOBAL group_replication_bootstrap_group=OFF;" > /dev/null 2>&1
      break
    fi
    gr_startup_chk $node1/node1.err
  done

  ${BASEDIR}/bin/mysqld --no-defaults \
    --basedir=${BASEDIR} --datadir=$node2 \
    --innodb_file_per_table $MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --server_id=1 --gtid_mode=ON --enforce_gtid_consistency=ON \
    --master_info_repository=TABLE --relay_log_info_repository=TABLE \
    --binlog_checksum=NONE --log_slave_updates=ON --log_bin=binlog \
    --binlog_format=ROW --innodb_flush_method=O_DIRECT \
    --core-file --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=$node2/error.log \
    --socket=$node2/node2_socket.sock --log-output=none \
    --port=$RBASE2 --transaction_write_set_extraction=XXHASH64 \
    --loose-group_replication_group_name="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
    --loose-group_replication_start_on_boot=off --loose-group_replication_local_address="$LADDR2" \
    --loose-group_replication_group_seeds="$LADDR1,$LADDR2,$LADDR3" \
    --loose-group_replication_bootstrap_group=off --super_read_only=OFF > $node2/node2.err 2>&1 &

  for X in $(seq 0 200); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$node2/node2_socket.sock ping > /dev/null 2>&1; then
      sleep 2
      ${BASEDIR}/bin/mysql -uroot -S$node2/node2_socket.sock -Bse "SET SQL_LOG_BIN=0;CREATE USER rpl_user@'%';GRANT REPLICATION SLAVE ON *.* TO rpl_user@'%' IDENTIFIED BY 'rpl_pass';FLUSH PRIVILEGES;SET SQL_LOG_BIN=1;" > /dev/null 2>&1
      ${BASEDIR}/bin/mysql -uroot -S$node2/node2_socket.sock -Bse "CHANGE MASTER TO MASTER_USER='rpl_user', MASTER_PASSWORD='rpl_pass' FOR CHANNEL 'group_replication_recovery';" > /dev/null 2>&1
      ${BASEDIR}/bin/mysql -uroot -S$node2/node2_socket.sock -Bse "INSTALL PLUGIN group_replication SONAME 'group_replication.so';START GROUP_REPLICATION;" > /dev/null 2>&1
      break
    fi
    gr_startup_chk $node2/node2.err
  done

  ${BASEDIR}/bin/mysqld --no-defaults \
    --basedir=${BASEDIR} --datadir=$node3 \
    --innodb_file_per_table $MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --server_id=1 --gtid_mode=ON --enforce_gtid_consistency=ON \
    --master_info_repository=TABLE --relay_log_info_repository=TABLE \
    --binlog_checksum=NONE --log_slave_updates=ON --log_bin=binlog \
    --binlog_format=ROW --innodb_flush_method=O_DIRECT \
    --core-file --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=$node3/error.log \
    --socket=$node3/node3_socket.sock --log-output=none \
    --port=$RBASE3 --transaction_write_set_extraction=XXHASH64 \
    --loose-group_replication_group_name="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
    --loose-group_replication_start_on_boot=off --loose-group_replication_local_address="$LADDR3" \
    --loose-group_replication_group_seeds="$LADDR1,$LADDR2,$LADDR3" \
    --loose-group_replication_bootstrap_group=off --super_read_only=OFF > $node3/node3.err 2>&1 &

  for X in $(seq 0 200); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$node3/node3_socket.sock ping > /dev/null 2>&1; then
      sleep 2
      ${BASEDIR}/bin/mysql -uroot -S$node3/node3_socket.sock -Bse "SET SQL_LOG_BIN=0;CREATE USER rpl_user@'%';GRANT REPLICATION SLAVE ON *.* TO rpl_user@'%' IDENTIFIED BY 'rpl_pass';FLUSH PRIVILEGES;SET SQL_LOG_BIN=1;" > /dev/null 2>&1
      ${BASEDIR}/bin/mysql -uroot -S$node3/node3_socket.sock -Bse "CHANGE MASTER TO MASTER_USER='rpl_user', MASTER_PASSWORD='rpl_pass' FOR CHANNEL 'group_replication_recovery';" > /dev/null 2>&1
      ${BASEDIR}/bin/mysql -uroot -S$node3/node3_socket.sock -Bse "INSTALL PLUGIN group_replication SONAME 'group_replication.so';START GROUP_REPLICATION;" > /dev/null 2>&1
      break
    fi
    gr_startup_chk $node3/node3.err
  done
}

start_mysqld_main(){
  COUNT_MYSQLDOPTIONS=`echo ${MYEXTRA} | wc -w`
  echo "SCRIPT_DIR=\$(cd \$(dirname \$0) && pwd)" > $WORK_START
  echo "source \$SCRIPT_DIR/${EPOCH}_mybase" >> $WORK_START
  echo "echo \"Attempting to start mysqld (socket /dev/shm/${EPOCH}/socket.sock)...\"" >> $WORK_START
  #echo $JE1 >> $WORK_START; echo $JE2 >> $WORK_START; echo $JE3 >> $WORK_START; echo $JE4 >> $WORK_START;echo $JE5 >> $WORK_START
  echo $JE1 >> $WORK_START; echo $JE2 >> $WORK_START; echo $JE3 >> $WORK_START; echo $JE4 >> $WORK_START
  echo "BIN=\`find \${BASEDIR} -maxdepth 2 -name mysqld -type f -o -name mysqld-debug -type f | head -1\`;if [ -z "\$BIN" ]; then echo \"Assert! mysqld binary '\$BIN' could not be read\";exit 1;fi" >> $WORK_START
  SCHEDULER_OR_NOT=
  if [ $ENABLE_QUERYTIMEOUT -gt 0 ]; then SCHEDULER_OR_NOT="--event-scheduler=ON "; fi
  # Change --port=$MYPORT to --skip-networking instead once BUG#13917335 is fixed and remove all MYPORT + MULTI_MYPORT coding
  if [ $MODE -ge 6 -a $TS_DEBUG_SYNC_REQUIRED_FLAG -eq 1 ]; then
    echo "${TIMEOUT_COMMAND} \$BIN --no-defaults --basedir=\${BASEDIR} --datadir=$WORKD/data --tmpdir=$WORKD/tmp \
                         --port=$MYPORT --pid-file=$WORKD/pid.pid --socket=$WORKD/socket.sock \
                         --loose-debug-sync-timeout=$TS_DS_TIMEOUT $MYEXTRA $TOKUDB $ROCKSDB --log-error=$WORKD/error.log.out ${SCHEDULER_OR_NOT}\
                         > $WORKD/mysqld.out 2>&1 &" | sed 's/ \+/ /g' >> $WORK_START
    CMD="${TIMEOUT_COMMAND} ${BIN} --no-defaults --basedir=$BASEDIR --datadir=$WORKD/data --tmpdir=$WORKD/tmp \
                         --port=$MYPORT --pid-file=$WORKD/pid.pid --socket=$WORKD/socket.sock \
                         --loose-debug-sync-timeout=$TS_DS_TIMEOUT --user=$MYUSER $MYEXTRA $TOKUDB $ROCKSDB --log-error=$WORKD/error.log.out ${SCHEDULER_OR_NOT}"
    if [ "${CHK_LOGBIN}" == "1" ];then
      CMD="${CMD} --server-id=100"
      sed -i "s|--no-defaults|--no-defaults --server-id=100|" $WORK_START
    fi
    MYSQLD_START_TIME=$(date +'%s')
    $CMD > $WORKD/mysqld.out 2>&1 &
    PIDV="$!"
  else
    echo "${TIMEOUT_COMMAND} \$BIN --no-defaults --basedir=\${BASEDIR} --datadir=$WORKD/data --tmpdir=$WORKD/tmp \
                         --port=$MYPORT --pid-file=$WORKD/pid.pid --socket=$WORKD/socket.sock $MYEXTRA $TOKUDB $ROCKSDB --log-error=$WORKD/error.log.out ${SCHEDULER_OR_NOT}\
                         > $WORKD/mysqld.out 2>&1 &" | sed 's/ \+/ /g' >> $WORK_START
    CMD="${TIMEOUT_COMMAND} ${BIN} --no-defaults --basedir=$BASEDIR --datadir=$WORKD/data --tmpdir=$WORKD/tmp \
                         --port=$MYPORT --pid-file=$WORKD/pid.pid --socket=$WORKD/socket.sock \
                         --user=$MYUSER $MYEXTRA $TOKUDB $ROCKSDB --log-error=$WORKD/error.log.out ${SCHEDULER_OR_NOT}"
    if [ "${CHK_LOGBIN}" == "1" ];then
      CMD="${CMD} --server-id=100"
      sed -i "s|--no-defaults|--no-defaults --server-id=100|" $WORK_START
    fi
    MYSQLD_START_TIME=$(date +'%s')
    $CMD > $WORKD/mysqld.out 2>&1 &
    PIDV="$!"
  fi
  sed -i "s|$WORKD|/dev/shm/${EPOCH}|g" $WORK_START
  sed -i "s|pid.pid|pid.pid --core-file|" $WORK_START
  # RV 04/05/17: The following sed line is causing issues with RocksDB, like this;
  # --plugin-load-add=RocksDB=ha_rocksdb.so\;rocksdb_cfstats=ha_rocksdb.so;rocks...
  # The adding of a \ (and especially a single one?!) does not make any sense atm, but there was highly like a historical reason
  # Disabling it for the moment. If any issues are seen, it can be reverted
  # sed -i "s|\.so\;|\.so\\\;|" $WORK_START
  chmod +x $WORK_START
  for X in $(seq 1 120); do
    sleep 1; if $BASEDIR/bin/mysqladmin -uroot -S$WORKD/socket.sock ping > /dev/null 2>&1; then break; fi
    # Check if the server crashed or shutdown, then there is no need to wait any longer (new beta feature as of 1 July 16)
    # RV fix made 10 Jan 17; if no error.log.out is created (for whatever reason) then 120x4 'not found' messages scroll on the screen: added '2>/dev/null'. The Reason for the
    #   missing error.log.out files in some circumstances needs to be found (seems to be related to bad startup options (usually in stage 8), but why is there no output at all?)
    if grep -E --binary-files=text -qi "identify the cause of the crash" $WORKD/error.log.out 2>/dev/null; then break; fi
    if grep -E --binary-files=text -qi "Writing a core file" $WORKD/error.log.out 2>/dev/null; then break; fi
    if grep -E --binary-files=text -qi "terribly wrong" $WORKD/error.log.out 2>/dev/null; then break; fi
    if grep -E --binary-files=text -qi "Shutdown complete" $WORKD/error.log.out 2>/dev/null; then break; fi
  done
}

#                             --binlog-format=MIXED \
start_valgrind_mysqld_main(){
  if [ -f $WORKD/valgrind.out ]; then mv -f $WORKD/valgrind.out $WORKD/valgrind.prev; fi
  SCHEDULER_OR_NOT=
  if [ $ENABLE_QUERYTIMEOUT -gt 0 ]; then SCHEDULER_OR_NOT="--event-scheduler=ON "; fi
  CMD="${TIMEOUT_COMMAND} valgrind --suppressions=$BASEDIR/mysql-test/valgrind.supp --num-callers=40 --show-reachable=yes \
              ${BIN} --basedir=${BASEDIR} --datadir=$WORKD/data --port=$MYPORT --tmpdir=$WORKD/tmp \
                              --pid-file=$WORKD/pid.pid --socket=$WORKD/socket.sock --user=$MYUSER $MYEXTRA $TOKUDB $ROCKSDB \
                              --log-error=$WORKD/error.log.out ${SCHEDULER_OR_NOT}"
                              # Workaround for BUG#12939557 (when old Valgrind version is used): --innodb_checksum_algorithm=none 
  MYSQLD_START_TIME=$(date +'%s')
  $CMD > $WORKD/valgrind.out 2>&1 &
  
  PIDV="$!"; STARTUPCOUNT=$[$STARTUPCOUNT+1]
  echo "SCRIPT_DIR=\$(cd \$(dirname \$0) && pwd)" > $WORK_START_VALGRIND
  echo "source \$SCRIPT_DIR/${EPOCH}_mybase" >> $WORK_START_VALGRIND
  echo "echo \"Attempting to start mysqld under Valgrind (socket /dev/shm/${EPOCH}/socket.sock)...\"" >> $WORK_START_VALGRIND
  echo $JE1 >> $WORK_START_VALGRIND; echo $JE2 >> $WORK_START_VALGRIND; echo $JE3 >> $WORK_START_VALGRIND
  #echo $JE4 >> $WORK_START_VALGRIND; echo $JE5 >> $WORK_START_VALGRIND
  echo $JE4 >> $WORK_START_VALGRIND
  echo "BIN=\`find \${BASEDIR} -maxdepth 2 -name mysqld -type f -o  -name mysqld-debug -type f | head -1\`;if [ -z "\$BIN" ]; then echo \"Assert! mysqld binary '\$BIN' could not be read\";exit 1;fi" >> $WORK_START_VALGRIND
  echo "valgrind --suppressions=\${BASEDIR}/mysql-test/valgrind.supp --num-callers=40 --show-reachable=yes \
       \$BIN --basedir=\${BASEDIR} --datadir=$WORKD/data --port=$MYPORT --tmpdir=$WORKD/tmp \
       --pid-file=$WORKD/pid.pid --log-error=$WORKD/error.log.out \
       --socket=$WORKD/socket.sock $MYEXTRA $TOKUDB $ROCKSDB ${SCHEDULER_OR_NOT}>>$WORKD/error.log.out 2>&1 &" | sed 's/ \+/ /g' >> $WORK_START_VALGRIND
  sed -i "s|$WORKD|/dev/shm/${EPOCH}|g" $WORK_START_VALGRIND
  sed -i "s|pid.pid|pid.pid --core-file|" $WORK_START_VALGRIND
  sed -i "s|\.so\;|\.so\\\;|" $WORK_START_VALGRIND
  chmod +x $WORK_START_VALGRIND
  for X in $(seq 1 360); do 
    sleep 1; if $BASEDIR/bin/mysqladmin -uroot -S$WORKD/socket.sock ping > /dev/null 2>&1; then break; fi
  done
  if ! $BASEDIR/bin/mysqladmin -uroot -S$WORKD/socket.sock ping > /dev/null 2>&1; then 
    echo_out "$ATLEASTONCE [Stage $STAGE] [ERROR] Failed to start mysqld server under Valgrind, check $WORKD/error.log.out, $WORKD/valgrind.out and $WORKD/init.log"
    echo "Terminating now."
    exit 1
  fi
}

determine_chunk(){
  if [ $NOISSUEFLOW -lt 0 ]; then NOISSUEFLOW=0; fi
  # Slow down chunk size scaling (both for CHUNK reductions and increases) by not modifying the chunk for SLOW_DOWN_CHUNK_SCALING_NR loops of determine_chunk() i.e. trials
  if [ $SLOW_DOWN_CHUNK_SCALING -gt 0 ]; then
    CHUNK_LOOPS_DONE=$[CHUNK_LOOPS_DONE+1]
    if [ $CHUNK_LOOPS_DONE -le $SLOW_DOWN_CHUNK_SCALING_NR ]; then  # Need to ensure we can exit determine_chunk() early (have had enough _NR rounds/loops)
      if [ $CHUNK_LOOPS_DONE -lt 99999999999 ]; then  # Need to ensure that this is not the very first loop (where first CHUNK determination) (see set_internal_options())
        if [ $CHUNK -lt $LINECOUNTF ]; then  # Need to ensure that CHUNK is less then the filesize (to avoid wiping the whole testcase away)
          if [ $NOISSUEFLOW -gt 0 ]; then  # Need to ensure we haven't just seen the issue (in which case new CHUNK determination is best)
            if [ $CHUNK -gt 0 ]; then  # Need to ensure we do not have a negative CHUNK size
              return;  # Exit determine_chunk() early to do another loop with the same pre-established CHUNK size (i.e. SLOW_DOWN_CHUNK_SCALING in action)
            fi
          fi
        fi
      fi
    fi
  fi
  CHUNK_LOOPS_DONE=1
  if [ $LINECOUNTF -ge 1000 ]; then
    if [ $NOISSUEFLOW -ge 20 ]; then CHUNK=0
    elif [ $NOISSUEFLOW -ge 18 ]; then CHUNK=$[$LINECOUNTF/500]
    elif [ $NOISSUEFLOW -ge 15 ]; then CHUNK=$[$LINECOUNTF/200]
    elif [ $NOISSUEFLOW -ge 14 ]; then CHUNK=$[$LINECOUNTF/100]    # 1%
    elif [ $NOISSUEFLOW -ge 12 ]; then CHUNK=$[$LINECOUNTF/50]     # 2%
    elif [ $NOISSUEFLOW -ge 10 ]; then CHUNK=$[$LINECOUNTF/25]     # 4%
    elif [ $NOISSUEFLOW -ge  8 ]; then CHUNK=$[$LINECOUNTF/12]     # 8%
    elif [ $NOISSUEFLOW -ge  6 ]; then CHUNK=$[$LINECOUNTF/8]      # 12%
    elif [ $NOISSUEFLOW -ge  5 ]; then CHUNK=$[$LINECOUNTF/6]      # 16%
    elif [ $NOISSUEFLOW -ge  4 ]; then CHUNK=$[$LINECOUNTF/4]      # 25%
    elif [ $NOISSUEFLOW -ge  3 ]; then CHUNK=$[$LINECOUNTF/3]      # 33%
    elif [ $NOISSUEFLOW -ge  2 ]; then CHUNK=$[$LINECOUNTF/2]      # 50%
    elif [ $NOISSUEFLOW -ge  1 ]; then CHUNK=$[$LINECOUNTF*65/100] # 65%
    else CHUNK=$[$LINECOUNTF*80/100]                               # 80% delete
    fi
  else
    if   [ $NOISSUEFLOW -ge 15 ]; then CHUNK=0
    elif [ $NOISSUEFLOW -ge 14 ]; then CHUNK=$[$LINECOUNTF/500]
    elif [ $NOISSUEFLOW -ge 12 ]; then CHUNK=$[$LINECOUNTF/200]
    elif [ $NOISSUEFLOW -ge 10 ]; then CHUNK=$[$LINECOUNTF/100]
    elif [ $NOISSUEFLOW -ge  8 ]; then CHUNK=$[$LINECOUNTF/75]
    elif [ $NOISSUEFLOW -ge  6 ]; then CHUNK=$[$LINECOUNTF/50]
    elif [ $NOISSUEFLOW -ge  5 ]; then CHUNK=$[$LINECOUNTF/40]
    elif [ $NOISSUEFLOW -ge  4 ]; then CHUNK=$[$LINECOUNTF/30]     # 3%
    elif [ $NOISSUEFLOW -ge  3 ]; then CHUNK=$[$LINECOUNTF/20]     # 5%
    elif [ $NOISSUEFLOW -ge  2 ]; then CHUNK=$[$LINECOUNTF/10]     # 10%
    elif [ $NOISSUEFLOW -ge  1 ]; then CHUNK=$[$LINECOUNTF/6]      # 16%
    else CHUNK=$[$LINECOUNTF/4]                                    # 25% delete
    fi
  fi
  # For issues which are sporadic, gradually reducing the CHUNK is ok, as long as reduction is done much slower (reducer should not end up with single 
  # line removals per trial too quickly since this leads to very slow testcase reduction. So, a smarter algorithm can be used here based on the remaining
  # testcase size and a much slower/much less important $NOISSUEFLOW input ($NOISSUEFLOW 1/100th % input; if 50 no-issue-runs then reduce chunk by 50%)
  # The flow is different in subreducer: when an issue is found, all subreducers are terminated & restarted (with a new filesize and fresh/new chunksize)
  if [ $SPORADIC -eq 1 ]; then
    if   [ $LINECOUNTF -ge 10000 ]; then CHUNK=$[$LINECOUNTF/6];   # 16%
    elif [ $LINECOUNTF -ge 5000  ]; then CHUNK=$[$LINECOUNTF/7];   # 14%
    elif [ $LINECOUNTF -ge 2000  ]; then CHUNK=$[$LINECOUNTF/8];   # 12%
    elif [ $LINECOUNTF -ge 1000  ]; then CHUNK=$[$LINECOUNTF/9];   # 11%
    elif [ $LINECOUNTF -ge 500   ]; then CHUNK=$[$LINECOUNTF/10];  # 10%
    elif [ $LINECOUNTF -ge 200   ]; then CHUNK=$[$LINECOUNTF/12];  # 8%
    elif [ $LINECOUNTF -ge 100   ]; then CHUNK=$[$LINECOUNTF/15];  # 7%
    fi  # If $LINECOUNTF < 100 then the normal CHUNK size calculation above is fine.

    if [ $LINECOUNTF -ge 100 ]; then
      if [ $NOISSUEFLOW -lt 100 ]; then
        # Make chunk size (very) gradually smaller based on seeing issues or not
        CHUNK=$[($CHUNK*(((100*100)-($NOISSUEFLOW*100))/100))/100]  # As explained above. 100ths are used due to int limitation
      else
        CHUNK=$[$CHUNK/100]  # 1% of original chunk size
      fi
    fi
  fi
  # Protection against 0 CHUNK size
  if [ $CHUNK -lt 1 ]; then CHUNK=1; fi
}

control_backtrack_flow(){
  if   [ $NOISSUEFLOW -ge 100 ]; then NOISSUEFLOW=$[$NOISSUEFLOW-60]
  elif [ $NOISSUEFLOW -ge  70 ]; then NOISSUEFLOW=$[$NOISSUEFLOW-40]
  elif [ $NOISSUEFLOW -ge  40 ]; then NOISSUEFLOW=$[$NOISSUEFLOW-20]
  elif [ $NOISSUEFLOW -ge  20 ]; then NOISSUEFLOW=$[$NOISSUEFLOW-8]
  elif [ $NOISSUEFLOW -ge  10 ]; then NOISSUEFLOW=$[$NOISSUEFLOW-3]
  elif [ $NOISSUEFLOW -ge   1 ]; then NOISSUEFLOW=$[$NOISSUEFLOW-1]
  fi
}

cut_random_chunk(){
  RANDLINE=$[ ( $RANDOM % ( $[ $LINECOUNTF - $CHUNK - 1 ] + 1 ) ) + 1 ]
  if [ $RANDLINE -eq 1 ]; then RANDLINE=2; fi  # Do not filter first line which contains DROP/CREATE/USE of test db
  if [ $CHUNK -eq 1 -a $TRIAL -gt 5 ]; then STUCKTRIAL=$[ $STUCKTRIAL + 1 ]; fi
  if [ $CHUNK -eq 1 -a $STUCKTRIAL -gt 5 ]; then
    echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Now filtering line $RANDLINE (Current chunk size: stuck at 1)"
    sed -n "$RANDLINE ! p" $WORKF > $WORKT
  else
    ENDLINE=$[$RANDLINE+$CHUNK]
    REALCHUNK=$[$CHUNK+1]
    if [ $SPORADIC -eq 1 -a $LINECOUNTF -lt 100 ]; then
      echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Now filtering line(s) $RANDLINE to $ENDLINE (Current chunk size: $REALCHUNK: Sporadic issue; using a fixed % based chunk)"
    else
      echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Now filtering line(s) $RANDLINE to $ENDLINE (Current chunk size: $REALCHUNK)"
    fi
    sed -n "$RANDLINE,+$CHUNK ! p" $WORKF > $WORKT 
  fi
}

cut_fixed_chunk(){
  echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Now filtering line $CURRENTLINE (Current chunk size: fixed to 1)"
  sed -n "$CURRENTLINE ! p" $WORKF > $WORKT 
}

cut_threadsync_chunk(){
  if [ $TS_TRXS_SETS -gt 0 ]; then
    echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Now filtering out last $TS_TRXS_SETS command sets"
  fi
  for t in $(eval echo {1..$TS_THREADS}); do 
    export TS_WORKF=$(eval echo $(echo '$WORKF'"$t"))
    export TS_WORKT=$(eval echo $(echo '$WORKT'"$t"))
    if [ $TS_TRXS_SETS -gt 0 ]; then
      FIRST_DS_OCCURENCE=$(tac $TS_WORKF | grep -E -v "^[\t ]*;[\t ]*$" | grep -E -m1 -n "SET DEBUG_SYNC" | awk -F":" '{print $1}'); 
      if grep -E --binary-files=text -qi "SIGNAL GO_T2" $TS_WORKF; then
        # Control thread
        LAST_LINE=$( \
        if [ $FIRST_DS_OCCURENCE -gt 1 ]; then \
          tac $TS_WORKF | awk '/now SIGNAL GO_T2/,/SET DEBUG_SYNC/ {print NR; i++; if (i>$TS_TRXS_SETS) nextfile}' | tail -n1; \
        else \
          tac $TS_WORKF | awk '/now SIGNAL GO_T2/,/SET DEBUG_SYNC/ {print NR; i++; if (i>1+$TS_TRXS_SETS) nextfile}' | tail -n1; \
        fi)
        if [ $TS_VARIABILITY_SLEEP -gt 0 ]; then
          tail -n$LAST_LINE $TS_WORKF | grep -E -v "^[\t ]*;[\t ]*$" | \
            sed -e "s/SET DEBUG_SYNC\(.*\)now SIGNAL GO_T2/SELECT SLEEP($TS_VARIABILITY_SLEEP);SET DEBUG_SYNC\1now SIGNAL GO_T2/" > $TS_WORKT
        else
          tail -n$LAST_LINE $TS_WORKF | grep -E --binary-files=text -v "^[\t ]*;[\t ]*$" > $TS_WORKT
        fi
      else
        # Sub threads
        LAST_LINE=$( \
        if [ $FIRST_DS_OCCURENCE -gt 1 ]; then \
          tac $TS_WORKF | awk '/now WAIT_FOR GO_T/,/SET DEBUG_SYNC/ {print NR; i++; if (i>$TS_TRXS_SETS) nextfile}' | tail -n1; \
        else \
          tac $TS_WORKF | awk '/now WAIT_FOR GO_T/,/SET DEBUG_SYNC/ {print NR; i++; if (i>1+$TS_TRXS_SETS) nextfile}' | tail -n1; \
        fi)
        if [ $TS_VARIABILITY_SLEEP -gt 0 ]; then
          TS_VARIABILITY_SLEEP_TENTH=$(echo "$TS_VARIABILITY_SLEEP / 10" | bc -l)
          tail -n$LAST_LINE $TS_WORKF | grep -E -v "^[\t ]*;[\t ]*$" | \
            sed -e "s/SET DEBUG_SYNC/SELECT SLEEP($TS_VARIABILITY_SLEEP_TENTH);SET DEBUG_SYNC/" > $TS_WORKT
        else
          tail -n$LAST_LINE $TS_WORKF | grep -E --binary-files=text -v "^[\t ]*;[\t ]*$" > $TS_WORKT
        fi
      fi
    else
      cat $TS_WORKF > $TS_WORKT
    fi
  done
}

run_and_check(){
  start_mysqld_or_valgrind_or_pxc
  run_sql_code
  if [ $MODE -eq 0 -o $MODE -eq 1 -o $MODE -eq 6 ]; then stop_mysqld_or_pxc; fi
  process_outcome
  OUTCOME="$?"
  if [ $MODE -ne 0 -a $MODE -ne 1 -a $MODE -ne 6 ]; then stop_mysqld_or_pxc; fi
  # Add error log from this trial to the overall run error log
  if [[ $PXC_MOD -eq 1 || $GRP_RPL_MOD -eq 1 ]]; then
    sudo cat $WORKD/node1/error.log > $WORKD/node1_error.log
    sudo cat $WORKD/node2/error.log > $WORKD/node2_error.log
    sudo cat $WORKD/node3/error.log > $WORKD/node3_error.log
  else
    cat $WORKD/error.log.out >> $WORKD/error.log
    rm -f $WORKD/error.log.out 
  fi
  return $OUTCOME
}

run_sql_code(){
  if [ $PXC_MOD -eq 0 ]; then
    mkdir $WORKD/data/test > /dev/null 2>&1 # Ensuring reducer can connect to the test database
  fi
  if [ $ENABLE_QUERYTIMEOUT -gt 0 ]; then 
    # Setting up query timeouts using the MySQL Event Scheduler
    # Place event into the mysql db, not test db as the test db is dropped immediately
    SOCKET_TO_BE_USED=
    if [[ $PXC_MOD -eq 1 || $GRP_RPL_MOD -eq 1 ]]; then
      SOCKET_TO_BE_USED=${node1}/node1_socket.sock
    else
      SOCKET_TO_BE_USED=$WORKD/socket.sock
    fi
    $BASEDIR/bin/mysql -uroot -S${SOCKET_TO_BE_USED} --force mysql -e"
      DELIMITER ||
      CREATE EVENT querytimeout ON SCHEDULE EVERY 20 SECOND DO BEGIN
      SET @id:='';
      SET @id:=(SELECT id FROM INFORMATION_SCHEMA.PROCESSLIST WHERE ID<>CONNECTION_ID() AND STATE<>'killed' AND TIME>$QUERYTIMEOUT ORDER BY TIME DESC LIMIT 1);
      IF @id > 1 THEN KILL QUERY @id; END IF;
      END ||
      DELIMITER ;
    "
  fi
  #DEBUG 
  #read -p "Go! (run_sql_code break)"
  if   [ $MODE -ge 6 ]; then
    echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [DATA] Loading datafile before SQL threads replay"
    if [ $TS_DBG_CLI_OUTPUT -eq 0 ]; then
      (echo "$DROPC"; (cat $TS_DATAINPUTFILE | grep -E --binary-files=text -v "$DROPC")) | $BASEDIR/bin/mysql -uroot -S$WORKD/socket.sock --force      test > /dev/null 2>/dev/null
    else
      (echo "$DROPC"; (cat $TS_DATAINPUTFILE | grep -E --binary-files=text -v "$DROPC")) | $BASEDIR/bin/mysql -uroot -S$WORKD/socket.sock --force -vvv test > $WORKD/mysql_data.out 2>&1
    fi
    TXT_OUT="$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [SQL] Forking SQL threads [PIDs]:"
    for t in $(eval echo {1..$TS_THREADS}); do 
      # Forking background threads by using bash fork implementation $() &
      export TS_WORKT=$(eval echo $(echo '$WORKT'"$t"))
      if [ $TS_DBG_CLI_OUTPUT -eq 0 ]; then
        $(cat $TS_WORKT | $BASEDIR/bin/mysql -uroot -S$WORKD/socket.sock --force      test > /dev/null 2>/dev/null  ) & 
      else
        $(cat $TS_WORKT | $BASEDIR/bin/mysql -uroot -S$WORKD/socket.sock --force -vvv test > $WORKD/mysql$t.out 2>&1 ) & 
      fi
      PID=$!
      export TS_THREAD_PID$t=$PID
      TXT_OUT="$TXT_OUT #$t [$!]"
    done
    echo_out "$TXT_OUT" 
    # Wait for forked processes to terminate
    echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [SQL] Waiting for all forked SQL threads to finish/terminate"
    TXT_OUT="$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [SQL] Finished/Terminated SQL threads:"
    for t in $(eval echo {$TS_THREADS..1}); do  # Reverse: later threads are likely to finish earlier
      wait $(eval echo $(echo '$TS_THREAD_PID'"$t"))
      TXT_OUT="$TXT_OUT #$t"
      echo_out_overwrite "$TXT_OUT"
      if [ $t -eq 20 -a $TS_THREADS -gt 20 ]; then
        echo_out "$TXT_OUT"
        TXT_OUT="$ATLEASTONCE [Stage $STAGE] [MULTI] Finished/Terminated subreducer threads:"
      fi
    done
    echo_out "$TXT_OUT"
    echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [SQL] All SQL threads have finished/terminated"
  elif [ $MODE -eq 5 ]; then
    if [[ $PXC_MOD -eq 1 || $GRP_RPL_MOD -eq 1 ]]; then
      cat $WORKT | $BASEDIR/bin/mysql -uroot -S${node1}/node1_socket.sock -vvv --force test > $WORKD/mysql.out 2>&1
    else
      cat $WORKT | $BASEDIR/bin/mysql -uroot -S$WORKD/socket.sock -vvv --force test > $WORKD/mysql.out 2>&1
    fi
  else
    # Some general information on MODE=2 replay using either the mysql CLI or pquery: When using the mysql cli, a single or double quote in and by itself
    # (without a terminating one on the same line) will cause the query to be seen as multi-line. With pquery this is not the case because it is an API/C
    # driven per-query executor. If a query fails (one per line), that query alone will fail, not subsequent ones - which would fail in the mysql CLI client
    # because of such an "incorrect opening of a multi-line statement". Hence, the reproducibility of a testcase using another replay tool (pquery testcase
    # being replayed with mysql CLI or vice versa) may differ. Another difference is that the pquery replay output looks significantly different from the
    # client replay output. Thus, any TEXT="..." strings need to be matched to the specific output seen in the original trial's pquery or mysql CLI output.
    if [ $PQUERY_MOD -eq 1 ]; then
      export LD_LIBRARY_PATH=${BASEDIR}/lib
      if [ -r $WORKD/pquery.out ]; then
        mv $WORKD/pquery.out $WORKD/pquery.prev
      fi
      PQUERY_MODE2_CLIENT_LOGGING=
      if [ $MODE -eq 2 ]; then
        PQUERY_MODE2_CLIENT_LOGGING="--log-all-queries --log-failed-queries"
      fi
      if [[ $PXC_MOD -eq 1 || $GRP_RPL_MOD -eq 1 ]]; then
        if [ $PQUERY_MULTI -eq 1 ]; then
          if [ $PQUERY_REVERSE_NOSHUFFLE_OPT -eq 1 ]; then PQUERY_SHUFFLE="--no-shuffle"; else PQUERY_SHUFFLE=""; fi
          $PQUERY_LOC --infile=$WORKT --database=test $PQUERY_SHUFFLE --threads=$PQUERY_MULTI_CLIENT_THREADS --queries=$PQUERY_MULTI_QUERIES $PQUERY_MODE2_CLIENT_LOGGING --user=root --socket=${node1}/node1_socket.sock --log-all-queries --log-failed-queries $PQUERY_EXTRA_OPTIONS > $WORKD/pquery.out 2>&1
        else
          if [ $PQUERY_REVERSE_NOSHUFFLE_OPT -eq 1 ]; then PQUERY_SHUFFLE=""; else PQUERY_SHUFFLE="--no-shuffle"; fi
          $PQUERY_LOC --infile=$WORKT --database=test $PQUERY_SHUFFLE --threads=1 $PQUERY_MODE2_CLIENT_LOGGING --user=root --socket=${node1}/node1_socket.sock --log-all-queries --log-failed-queries $PQUERY_EXTRA_OPTIONS > $WORKD/pquery.out 2>&1
        fi
      else
        if [ $PQUERY_MULTI -eq 1 ]; then
          if [ $PQUERY_REVERSE_NOSHUFFLE_OPT -eq 1 ]; then PQUERY_SHUFFLE="--no-shuffle"; else PQUERY_SHUFFLE=""; fi
          $PQUERY_LOC --infile=$WORKT --database=test $PQUERY_SHUFFLE --threads=$PQUERY_MULTI_CLIENT_THREADS --queries=$PQUERY_MULTI_QUERIES $PQUERY_MODE2_CLIENT_LOGGING --user=root --socket=$WORKD/socket.sock --logdir=$WORKD --log-all-queries --log-failed-queries $PQUERY_EXTRA_OPTIONS > $WORKD/pquery.out 2>&1
        else
          if [ $PQUERY_REVERSE_NOSHUFFLE_OPT -eq 1 ]; then PQUERY_SHUFFLE=""; else PQUERY_SHUFFLE="--no-shuffle"; fi
          $PQUERY_LOC --infile=$WORKT --database=test $PQUERY_SHUFFLE --threads=1 $PQUERY_MODE2_CLIENT_LOGGING --user=root --socket=$WORKD/socket.sock --logdir=$WORKD --log-all-queries --log-failed-queries $PQUERY_EXTRA_OPTIONS > $WORKD/pquery.out 2>&1
        fi
      fi
    else
      if [ "$CLI_MODE" == "" ]; then CLI_MODE=99; fi  # Leads to assert below
      CLIENT_SOCKET=
      if [[ $PXC_MOD -eq 1 || $GRP_RPL_MOD -eq 1 ]]; then
        CLIENT_SOCKET=${node1}/node1_socket.sock
      else
        CLIENT_SOCKET=$WORKD/socket.sock 
      fi
      case $CLI_MODE in
        0) cat $WORKT | $BASEDIR/bin/mysql -uroot -S${CLIENT_SOCKET} --binary-mode --force test > $WORKD/mysql.out 2>&1 ;;
        1) $BASEDIR/bin/mysql -uroot -S${CLIENT_SOCKET} --execute="SOURCE ${WORKT};" --force test > $WORKD/mysql.out 2>&1 ;;  # When http://bugs.mysql.com/bug.php?id=81782 is fixed, re-add --binary-mode to this command. Also note that due to http://bugs.mysql.com/bug.php?id=81784, the --force option has to be after the --execute option.
        2) $BASEDIR/bin/mysql -uroot -S${CLIENT_SOCKET} --binary-mode --force test < ${WORKT} > $WORKD/mysql.out 2>&1 ;;
        *) echo_out "Assert: default clause in CLI_MODE switchcase hit (in run_sql_code). This should not happen. CLI_MODE=${CLI_MODE}"; exit 1 ;;
      esac
    fi
  fi
  sleep 1
}

cleanup_and_save(){
  if [ $MODE -ge 6 ]; then
    if [ "$STAGE" = "T" ]; then rm -Rf $WORKD/log/*.sql; fi
    rm -Rf $WORKD/out/*.sql
    for t in $(eval echo {1..$TS_THREADS}); do
      export TS_WORKF=$(eval echo $(echo '$WORKF'"$t"))
      export TS_WORKT=$(eval echo $(echo '$WORKT'"$t"))
      export TS_WORKO=$(eval echo $(echo '$WORKO'"$t"))
      cp -f $TS_WORKT $TS_WORKF
      cp -f $TS_WORKT $TS_WORKO
      if [ "$STAGE" = "T" ]; then
        export TS_WORKO_TE_FILE=$(eval echo $(echo '$WORKO'"$t") | sed 's/_out//g;s/\/out/\/log/g')
        # Do not copy the eliminated thread
        if [ ! $t -eq $TS_ELIMINATION_THREAD_ID ]; then
          cp -f $TS_WORKO $TS_WORKO_TE_FILE
        fi
      fi
    done
    if [ "$STAGE" = "T" ]; then
      # Move workdir
      if [ $TS_TE_DIR_SWAP_DONE -eq 1 ]; then
        echo_out "[Info] ThreadSync input directory now set to $WORKD/log after a thread was eliminated (Directory was re-initialized)"
      else
        echo_out "[Info] ThreadSync input directory now set to $WORKD/log after a thread was eliminated"
        TS_TE_DIR_SWAP_DONE=1
      fi
      cp -f $TS_ORIG_DATAINPUTFILE $WORKD/log
      TS_THREADS=$[$TS_THREADS-1]
      TS_ELIMINATED_THREAD_COUNT=$[$TS_ELIMINATED_THREAD_COUNT+1]
      TS_INPUTDIR=$WORKD/log
      TS_init_all_sql_files
    fi
  else
    if [[ $PXC_MOD -eq 1 || $GRP_RPL_MOD -eq 1 ]]; then
      (ps -ef | grep -E 'node1_socket\|node2_socket\|node3_socket' | grep -E -v grep -E | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true)
      sleep 2; sync
    fi
    cp -f $WORKT $WORKF
    if [ -r "$WORKO" ]; then  # First occurence: there is no $WORKO yet
      cp -f $WORKO ${WORKO}.prev
      # Save a testcase backup (this is useful if [oddly] the issue now fails to reproduce)
      echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Previous good testcase backed up as $WORKO.prev"
    fi
    grep -E -v "^# mysqld options required for replay:" $WORKT > $WORKO
    sed -i "1 i\# mysqld options required for replay: $TOKUDB $ROCKSDB $MYEXTRA" $WORKO
    sed -i "s|[ \t]\+| |g" $WORKO
    cp -f $WORKO $WORK_OUT
    # Save a tarball of full self-contained testcase on each successful reduction
    BUGTARDIR=$(echo $WORKO | sed 's|/[^/]\+$||;s|/$||')
    rm -f $BUGTARDIR/${EPOCH}_bug_bundle.tar.gz
    $(cd $BUGTARDIR; tar -zhcf ${EPOCH}_bug_bundle.tar.gz ${EPOCH}*)
  fi
  ATLEASTONCE="[*]"  # The issue was seen at least once (this is used to permanently mark lines with '[*]' suffix as soon as this happens)
  if [ ${STAGE} -eq 8 ]; then
    STAGE8_CHK=1
  fi
  if [ ${STAGE} -eq 9 ]; then
    STAGE9_CHK=1
  fi
  # VERFIED file creation + subreducer handling
  echo "TRIAL:$TRIAL" > $WORKD/VERIFIED
  echo "WORKO:$WORKO" >> $WORKD/VERIFIED
  if [ "$MULTI_REDUCER" == "1" ]; then  # This is a subreducer
    echo "# $ATLEASTONCE Issue was reproduced during this simplification subreducer." >> $WORKD/VERIFIED
    echo_out "$ATLEASTONCE [Stage $STAGE] Issue was reproduced during this simplification subreducer. Terminating now." 
    # This is a simplification subreducer started by a parent/main reducer, to simplify an issue. We terminate now after discovering the issue here. 
    # We rely on the parent/main reducer to kill off mysqld processes (on the next multi_reducer() call - at the top of the function).
    finish $INPUTFILE
  else
    echo "# $ATLEASTONCE Issue was seen at least once during this run of reducer" >> $WORKD/VERIFIED
  fi
}

process_outcome(){
  if [ $NOISSUEFLOW -lt 0 ]; then NOISSUEFLOW=0; fi
  # MODE0: timeout/hang testing (SET TIMEOUT_CHECK)
  if [ $MODE -eq 0 ]; then
    if [ "${MYSQLD_START_TIME}" == '' ]; then
      echo "Assert: MYSQLD_START_TIME==''"
      echo "Terminating now."
      exit 1
    fi
    RUN_TIME=$[ $(date +'%s') - ${MYSQLD_START_TIME} ]
    if [ ${RUN_TIME} -ge ${TIMEOUT_CHECK_REAL} ]; then
      if [ ! "$STAGE" = "V" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*TimeoutBug*] [$NOISSUEFLOW] Swapping files & saving last known good timeout issue in $WORKO"
        control_backtrack_flow
      fi
      cleanup_and_save
      return 1
    else
      if [ ! "$STAGE" = "V" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [NoTimeoutBug] [$NOISSUEFLOW] Kill server $NEXTACTION"
        NOISSUEFLOW=$[$NOISSUEFLOW+1]
      fi
      return 0
    fi

  # MODE1: Valgrind output testing (set TEXT) 
  elif [ $MODE -eq 1 ]; then
    echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Waiting for Valgrind to terminate analysis" 
    while :; do
      sleep 1; sync
      if grep -E --binary-files=text -q "ERROR SUMMARY" $WORKD/valgrind.out; then break; fi
    done
    if grep -E --binary-files=text -iq "$TEXT" $WORKD/valgrind.out $WORKD/error.log.out; then
      if [ ! "$STAGE" = "V" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*ValgrindBug*] [$NOISSUEFLOW] Swapping files & saving last known good Valgrind issue in $WORKO" 
        control_backtrack_flow
      fi
      cleanup_and_save
      return 1 
    else
      if [ ! "$STAGE" = "V" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [NoValgrindBug] [$NOISSUEFLOW] Kill server $NEXTACTION"
        NOISSUEFLOW=$[$NOISSUEFLOW+1]
      fi
      return 0
    fi

  # MODE2: mysql CLI/pquery client output testing (set TEXT)
  elif [ $MODE -eq 2 ]; then
    FILETOCHECK=
    # Check if this is a pquery client output testing run
    if [ $PQUERY_MOD -eq 1 ]; then  # pquery client output testing run
      FILETOCHECK=$WORKD/default.node.tld_thread-0.out  # Could use improvement for multi-threaded runs
      FILETOCHECK2=$WORKD/default.node.tld_thread-0.sql
    else  # mysql CLI output testing run
      FILETOCHECK=$WORKD/mysql.out
    fi
    NEWLINENUMBER=""
    NEWLINENUMBER=$(grep -E "$QCTEXT" $FILETOCHECK2|grep -E -o "#[0-9]\+$"|sed 's/#//g')
    # TODO: Add check if same query has same output multiple times (add variable for number of occurences)
    if [ $(grep -E -c "$TEXT#$NEWLINENUMBER$" $FILETOCHECK) -gt 0 ]; then
      if [ ! "$STAGE" = "V" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*ClientOutputBug*] [$NOISSUEFLOW] Swapping files & saving last known good client output issue in $WORKO"
        control_backtrack_flow
      fi
      cleanup_and_save
      return 1
    else
      if [ ! "$STAGE" = "V" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [NoClientOutputBug] [$NOISSUEFLOW] Kill server $NEXTACTION"
        NOISSUEFLOW=$[$NOISSUEFLOW+1]
      fi
      return 0
    fi

  # MODE3: mysqld error output log testing (set TEXT)
  elif [ $MODE -eq 3 ]; then
    M3_ISSUE_FOUND=0
    ERRORLOG=
    if [[ $PXC_MOD -eq 1 || $GRP_RPL_MOD -eq 1 ]]; then
      ERRORLOG=$WORKD/*/error.log
      sudo chmod 777 $ERRORLOG
    else
      ERRORLOG=$WORKD/error.log.out
    fi
    if [ $REDUCE_GLIBC_OR_SS_CRASHES -gt 0 ]; then
      # A glibc crash looks similar to: *** Error in `/sda/PS180516-percona-server-5.6.30-76.3-linux-x86_64-debug/bin/mysqld': corrupted double-linked list: 0x00007feb2c0011e0 ***
      if grep -E --binary-files=text -iq '*** Error in' /tmp/reducer_typescript${TYPESCRIPT_UNIQUE_FILESUFFIX}.log; then
        if grep -E --binary-files=text -iq "$TEXT" /tmp/reducer_typescript${TYPESCRIPT_UNIQUE_FILESUFFIX}.log; then
          M3_ISSUE_FOUND=1
        fi
      fi
      # Stack smashing looks similar to: *** stack smashing detected ***: /sda/Percona-Server-5.7.13-6-Linux.x86_64.ssl101/bin/mysqld terminated
      if grep -E --binary-files=text -iq '*** stack smashing' /tmp/reducer_typescript${TYPESCRIPT_UNIQUE_FILESUFFIX}.log; then
        if grep -E --binary-files=text -iq "$TEXT" /tmp/reducer_typescript${TYPESCRIPT_UNIQUE_FILESUFFIX}.log; then
          M3_ISSUE_FOUND=1
        fi
      fi
      M3_OUTPUT_TEXT="ConsoleTypescript"
    else
      if [ $USE_TEXT_STRING -eq 1 ]; then
        rm -f ${ERRORLOG}.text_string
        touch ${ERRORLOG}.text_string
        $TEXT_STRING_LOC $ERRORLOG >> ${ERRORLOG}.text_string
        if grep -E --binary-files=text -iq "$TEXT" $ERRORLOG.text_string; then M3_ISSUE_FOUND=1; fi
        M3_OUTPUT_TEXT="TextString"
      else
        if grep -E --binary-files=text -iq "$TEXT" $ERRORLOG; then M3_ISSUE_FOUND=1; fi
        M3_OUTPUT_TEXT="ErrorLog"
      fi
    fi
    if [ $M3_ISSUE_FOUND -eq 1 ]; then
      if [ ! "$STAGE" = "V" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*${M3_OUTPUT_TEXT}OutputBug*] [$NOISSUEFLOW] Swapping files & saving last known good mysqld error log output issue in $WORKO" 
        control_backtrack_flow
      fi
      cleanup_and_save
      if [ $PXC_MOD -eq 0 ]; then
        return 1
      fi 
    else
      if [ ! "$STAGE" = "V" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [No${M3_OUTPUT_TEXT}OutputBug] [$NOISSUEFLOW] Kill server $NEXTACTION"
        NOISSUEFLOW=$[$NOISSUEFLOW+1]
      fi
      return 0
    fi
  
  # MODE4: Crash testing
  elif [ $MODE -eq 4 ]; then
    M4_ISSUE_FOUND=0
    if [ $PXC_MOD -eq 1 ]; then
      if [ $PXC_ISSUE_NODE -eq 0 -o $PXC_ISSUE_NODE -eq 1 ]; then
        if ! $BASEDIR/bin/mysqladmin -uroot --socket=${node1}/node1_socket.sock ping > /dev/null 2>&1; then M4_ISSUE_FOUND=1; fi
      fi
      if [ $PXC_ISSUE_NODE -eq 0 -o $PXC_ISSUE_NODE -eq 2 ]; then
        if ! $BASEDIR/bin/mysqladmin -uroot --socket=${node2}/node2_socket.sock ping > /dev/null 2>&1; then M4_ISSUE_FOUND=1; fi
      fi
      if [ $PXC_ISSUE_NODE -eq 0 -o $PXC_ISSUE_NODE -eq 3 ]; then
        if ! $BASEDIR/bin/mysqladmin -uroot --socket=${node3}/node3_socket.sock ping > /dev/null 2>&1; then M4_ISSUE_FOUND=1; fi
      fi
    elif [ $GRP_RPL_MOD -eq 1 ]; then
      if [ $GRP_RPL_ISSUE_NODE -eq 0 -o $GRP_RPL_ISSUE_NODE -eq 1 ]; then
        if ! $BASEDIR/bin/mysqladmin -uroot --socket=${node1}/node1_socket.sock ping > /dev/null 2>&1; then M4_ISSUE_FOUND=1; fi
      fi
      if [ $GRP_RPL_ISSUE_NODE -eq 0 -o $GRP_RPL_ISSUE_NODE -eq 2 ]; then
        if ! $BASEDIR/bin/mysqladmin -uroot --socket=${node2}/node2_socket.sock ping > /dev/null 2>&1; then M4_ISSUE_FOUND=1; fi
      fi
      if [ $GRP_RPL_ISSUE_NODE -eq 0 -o $GRP_RPL_ISSUE_NODE -eq 3 ]; then
        if ! $BASEDIR/bin/mysqladmin -uroot --socket=${node3}/node3_socket.sock ping > /dev/null 2>&1; then M4_ISSUE_FOUND=1; fi
      fi
    else
      if [ $REDUCE_GLIBC_OR_SS_CRASHES -gt 0 ]; then
        # A glibc crash looks similar to: *** Error in `/sda/PS180516-percona-server-5.6.30-76.3-linux-x86_64-debug/bin/mysqld': corrupted double-linked list: 0x00007feb2c0011e0 ***
        if grep -E --binary-files=text -iq '*** Error in' /tmp/reducer_typescript${TYPESCRIPT_UNIQUE_FILESUFFIX}.log; then
          M4_ISSUE_FOUND=1
        fi
        # Stack smashing looks similar to: *** stack smashing detected ***: /sda/Percona-Server-5.7.13-6-Linux.x86_64.ssl101/bin/mysqld terminated
        if grep -E --binary-files=text -iq '*** stack smashing' /tmp/reducer_typescript${TYPESCRIPT_UNIQUE_FILESUFFIX}.log; then
          M4_ISSUE_FOUND=1
        fi
      else
        if ! $BASEDIR/bin/mysqladmin -uroot -S$WORKD/socket.sock ping > /dev/null 2>&1; then M4_ISSUE_FOUND=1; fi
      fi
    fi
    if [ $REDUCE_GLIBC_OR_SS_CRASHES -gt 0 ]; then
      M4_OUTPUT_TEXT="GlibcCrash"
    else
      M4_OUTPUT_TEXT="Crash"
    fi 
    if [ $M4_ISSUE_FOUND -eq 1 ]; then
      if [ ! "$STAGE" = "V" ]; then
        if [ $STAGE -eq 6 ]; then 
          echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Column $COLUMN/$COUNTCOLS] [*$M4_OUTPUT_TEXT*] Swapping files & saving last known good crash in $WORKO"
        else
          echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*$M4_OUTPUT_TEXT*] [$NOISSUEFLOW] Swapping files & saving last known good crash in $WORKO"
        fi
        control_backtrack_flow
      fi
      cleanup_and_save
      return 1 
    else
      if [ ! "$STAGE" = "V" ]; then
        if [ $STAGE -eq 6 ]; then 
          echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Column $COLUMN/$COUNTCOLS] [No$M4_OUTPUT_TEXT] Kill server $NEXTACTION"
        else
          echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [No$M4_OUTPUT_TEXT] [$NOISSUEFLOW] Kill server $NEXTACTION"
        fi
        NOISSUEFLOW=$[$NOISSUEFLOW+1]
      fi
      return 0
    fi
  
  # MODE5: MTR testcase reduction testing (set TEXT)
  elif [ $MODE -eq 5 ]; then
    COUNT_TEXT_OCCURENCES=$(grep -E --binary-files=text -ic "$TEXT" $WORKD/mysql.out)
    if [ $COUNT_TEXT_OCCURENCES -ge $MODE5_COUNTTEXT ]; then
      COUNT_TEXT_OCCURENCES=$(grep -E --binary-files=text -ic "$MODE5_ADDITIONAL_TEXT" $WORKD/mysql.out)
      if [ $COUNT_TEXT_OCCURENCES -ge $MODE5_ADDITIONAL_COUNTTEXT ]; then
        if [ ! "$STAGE" = "V" ]; then
          echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*MTRCaseOutputBug*] [$NOISSUEFLOW] Swapping files & saving last known good MTR testcase output issue in $WORKO" 
          control_backtrack_flow
        fi
        cleanup_and_save
        return 1 
      else
        if [ ! "$STAGE" = "V" ]; then
          echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [NoMTRCaseOutputBug] [$NOISSUEFLOW] Kill server $NEXTACTION"
          NOISSUEFLOW=$[$NOISSUEFLOW+1]
        fi
        return 0
      fi
    else
      if [ ! "$STAGE" = "V" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [NoMTRCaseOutputBug] [$NOISSUEFLOW] Kill server $NEXTACTION"
        NOISSUEFLOW=$[$NOISSUEFLOW+1]
      fi
      return 0
    fi

  # MODE6: ThreadSync Valgrind output testing (set TEXT) 
  elif [ $MODE -eq 6 ]; then
    echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Waiting for Valgrind to terminate analysis" 
    while :; do
      sleep 1; sync
      if grep -E --binary-files=text -q "ERROR SUMMARY" $WORKD/valgrind.out; then break; fi
    done
    if grep -E --binary-files=text -iq "$TEXT" $WORKD/valgrind.out; then
      if [ "$STAGE" = "T" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*TSValgrindBug*] [$NOISSUEFLOW] Swapping files & saving last known good Valgrind issue thread file(s) in $WORKD/log/"
      elif [ ! "$STAGE" = "V" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*TSValgrindBug*] [$NOISSUEFLOW] Swapping files & saving last known good Valgrind issue thread file(s) in $WORKD/out/"
        control_backtrack_flow
      fi
      cleanup_and_save
      return 1 
    else
      if [ ! "$STAGE" = "V" -a ! "$STAGE" = "T" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [NoTSValgrindBug] [$NOISSUEFLOW] Kill server $NEXTACTION"
        NOISSUEFLOW=$[$NOISSUEFLOW+1]
      fi
      return 0
    fi

  # MODE7: ThreadSync mysql CLI output testing (set TEXT)
  elif [ $MODE -eq 7 ]; then
    if grep -E --binary-files=text -iq "$TEXT" $WORKD/mysql.out; then
      if [ "$STAGE" = "T" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*TSCLIOutputBug*] [$NOISSUEFLOW] Swapping files & saving last known good CLI output issue thread file(s) in $WORKD/log/"
      elif [ ! "$STAGE" = "V" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*TSCLIOutputBug*] [$NOISSUEFLOW] Swapping files & saving last known good CLI output issue thread file(s) in $WORKD/out/"
        control_backtrack_flow
      fi
      cleanup_and_save
      return 1 
    else
      if [ ! "$STAGE" = "V" -a ! "$STAGE" = "T" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [NoTSCLIOutputBug] [$NOISSUEFLOW] Kill server $NEXTACTION"
        NOISSUEFLOW=$[$NOISSUEFLOW+1]
      fi
      return 0
    fi

  # MODE8: ThreadSync mysqld error output log testing (set TEXT)
  elif [ $MODE -eq 8 ]; then
    if grep -E --binary-files=text -iq "$TEXT" $WORKD/error.log.out; then
      if [ "$STAGE" = "T" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*TSErrorLogOutputBug*] [$NOISSUEFLOW] Swapping files & saving last known good error log output issue thread file(s) in $WORKD/log/"
      elif [ ! "$STAGE" = "V" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*TSErrorLogOutputBug*] [$NOISSUEFLOW] Swapping files & saving last known good error log output issue thread file(s) in $WORKD/out/"
        control_backtrack_flow
      fi
      cleanup_and_save
      return 1 
    else
      if [ ! "$STAGE" = "V" -a ! "$STAGE" = "T" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [NoTSErrorLogOutputBug] [$NOISSUEFLOW] Kill server $NEXTACTION"
        NOISSUEFLOW=$[$NOISSUEFLOW+1]
      fi
      return 0
    fi
  
  # MODE9: ThreadSync Crash testing
  elif [ $MODE -eq 9 ]; then
    if ! $BASEDIR/bin/mysqladmin -uroot -S$WORKD/socket.sock ping > /dev/null 2>&1; then
      if [ "$STAGE" = "T" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*TSCrash*] [$NOISSUEFLOW] Swapping files & saving last known good crash thread file(s) in $WORKD/log/"
      elif [ ! "$STAGE" = "V" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [*TSCrash*] [$NOISSUEFLOW] Swapping files & saving last known good crash thread file(s) in $WORKD/out/"
        control_backtrack_flow
      fi
      cleanup_and_save
      return 1 
    else
      if [ ! "$STAGE" = "V" -a ! "$STAGE" = "T" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [NoTSCrash] [$NOISSUEFLOW] Kill server $NEXTACTION"
        NOISSUEFLOW=$[$NOISSUEFLOW+1]
      fi
      return 0
    fi

  # Invalid mode
  else
    echoit "Assert: invalid MODE (MODE=${MODE}) discovered. Terminating."
    exit 1
  fi
}

stop_mysqld_or_pxc(){
  SHUTDOWN_TIME_START=$(date +'%s')
  MODE0_MIN_SHUTDOWN_TIME=$[ $TIMEOUT_CHECK + 10 ]
  if [[ $PXC_MOD -eq 1 || $GRP_RPL_MOD -eq 1 ]]; then
    (ps -ef | grep -E 'node1_socket\|node2_socket\|node3_socket' | grep -E -v grep -E | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true)
    sleep 2; sync
  else
    if [ ${FORCE_KILL} -eq 1 -a ${MODE} -ne 0 ]; then  # In MODE=0 we may be checking for shutdown hang issues, so do not kill mysqld
      while :; do
        if kill -0 $PIDV > /dev/null 2>&1; then
          sleep 1
          kill -9 $PIDV
        else
          break
        fi
      done
    else
      # RV-15/09/14 Added timeout due to bug http://bugs.mysql.com/bug.php?id=73914
      # RV-02/12/14 We do not want too fast a shutdown either; quite a few bugs happen when mysqld is being shutdown
      # RV-22/03/17 To check for shutdown hangs, need to make sure that timeout of mysqladmin is longer then TIMEOUT_CHECK seconds + 10 seconds safety margin
      if [ $MODE -eq 0 ]; then
        timeout -k${MODE0_MIN_SHUTDOWN_TIME} -s9 ${MODE0_MIN_SHUTDOWN_TIME}s $BASEDIR/bin/mysqladmin -uroot -S$WORKD/socket.sock shutdown >> $WORKD/mysqld.out 2>&1
      else
        timeout -k40 -s9 40s $BASEDIR/bin/mysqladmin -uroot -S$WORKD/socket.sock shutdown >> $WORKD/mysqld.out 2>&1  # Note it is myqladmin being terminated with -9, not mysqld !
      fi
      if [ $MODE -eq 0 -o $MODE -eq 1 -o $MODE -eq 6 ]; then sleep 5; else sleep 1; fi
  
      # Try various things now to bring server down, upto kill -9
      while :; do
        sleep 1
        if kill -0 $PIDV > /dev/null 2>&1; then 
          if [ $MODE -eq 0 -o $MODE -eq 1 -o $MODE -eq 6 ]; then sleep 5; else sleep 2; fi
          if kill -0 $PIDV > /dev/null 2>&1; then $BASEDIR/bin/mysqladmin -uroot -S$WORKD/socket.sock shutdown >> $WORKD/mysqld.out 2>&1; else break; fi  # Retry shutdown one more time
          if [ $MODE -eq 0 -o $MODE -eq 1 -o $MODE -eq 6 ]; then sleep 5; else sleep 2; fi
          if kill -0 $PIDV > /dev/null 2>&1; then echo_out "$ATLEASTONCE [Stage $STAGE] [WARNING] Attempting to bring down server failed at least twice. Is this server very busy?"; else break; fi
          sleep 5
          if [ $MODE -ne 1 -a $MODE -ne 6 ]; then
            if [ $MODE -eq 0 ]; then
              if [ $[ $(date +'%s') - ${SHUTDOWN_TIME_START} ] -lt $MODE0_MIN_SHUTDOWN_TIME ]; then
                continue  # Do not proceed to kill -9 if server is hanging and reducer is checking for the same (i.e. MODE=0) untill we've passed $TIMEOUT_CHECK + 10 second safety margin
              fi
            fi
            if kill -0 $PIDV > /dev/null 2>&1; then 
              if [ $MODE -ne 0 ]; then  # For MODE=0, the following is not a WARNING but fairly normal
                echo_out "$ATLEASTONCE [Stage $STAGE] [WARNING] Attempting to bring down server failed. Now forcing kill of mysqld"
              fi
              kill -9 $PIDV
            else 
              break
            fi
          fi
        else
          break
        fi
      done
    fi
    PIDV=""
  fi
  RUN_TIME=$[ ${RUN_TIME} + $(date +'%s') - ${SHUTDOWN_TIME_START} ]  # Add shutdown runtime to overall runtime which is later checked against TIMEOUT_CHECK
}

finish(){
  if [ "${STAGE}" != "" -a "${STAGE8_CHK}" != "" ]; then  # Prevention for issue where ${STAGE} was empty on CTRL+C
    if [ ${STAGE} -eq 8 ]; then
      if [ "${CHK_LOGBIN}" == "1" ];then
        MYEXTRA="$MYEXTRA --server-id=100"
      fi
      if [ ${STAGE8_CHK} -eq 0 ]; then
        export -n MYEXTRA="$MYEXTRA ${STAGE8_OPT}"
        sed -i "s|error.log.out|error.log.out $MYEXTRA |" $WORK_START
      fi
    fi
  fi
  echo_out "[Finish] Finalized reducing SQL input file ($INPUTFILE)"
  echo_out "[Finish] Number of server startups         : $STARTUPCOUNT (not counting subreducers)"
  echo_out "[Finish] Working directory was             : $WORKD"
  echo_out "[Finish] Reducer log                       : $WORKD/reducer.log"
  if [ -s $WORKO ]; then  # If there were no issues found, $WORKO was never written
    cp -f $WORKO $WORK_OUT
    echo_out "[Finish] Final testcase                    : $WORKO ($(wc -l $WORKO | awk '{print $1}') lines)"
  else
    cp $INPUTFILE $WORK_OUT
    echo_out "[Finish] Final testcase                    : $INPUTFILE (= input file, no optimizations were successful. $(wc -l $WORKO | awk '{print $1}') lines)"
  fi
  BUGTARDIR=$(echo $WORKO | sed 's|/[^/]\+$||;s|/$||')
  rm -f $BUGTARDIR/${EPOCH}_bug_bundle.tar.gz
  $(cd $BUGTARDIR; tar -zhcf ${EPOCH}_bug_bundle.tar.gz ${EPOCH}*)
  echo_out "[Finish] Final testcase bundle + scripts in: $BUGTARDIR"
  echo_out "[Finish] Final testcase for script use     : $WORK_OUT (handy to use in combination with the scripts below)"
  echo_out "[Finish] File containing datadir           : $WORK_BASEDIR (All scripts below use this. Update this when basedir changes)"
  echo_out "[Finish] Matching data dir init script     : $WORK_INIT (This script will use /dev/shm/${EPOCH} as working directory)"
  echo_out "[Finish] Matching startup script           : $WORK_START (Starts mysqld with same options as used in reducer)"
  if [ $MODE -ge 6 ]; then
    # See init_workdir_and_files() and search for WORK_RUN for more info. Also more info in improvements section at top
    echo_out "[Finish] Matching run script               : $WORK_RUN (though you can look at this file for an example, implementation for MODE6+ is not finished yet)"
  else
    echo_out "[Finish] Matching run script (CLI)         : $WORK_RUN (executes the testcase via the mysql CLI)"
    echo_out "[Finish] Matching startup script (pquery)  : $WORK_RUN_PQUERY (executes the testcase via the pquery binary)"
  fi
  echo_out "[Finish] Final testcase bundle tar ball    : ${EPOCH}_bug_bundle.tar.gz (handy for upload to bug reports)"
  if [ "$MULTI_REDUCER" != "1" ]; then  # This is the parent/main reducer
    if [ "$MYEXTRA" != "" -o "$TOKUDB" != "" -o "$ROCKSDB" != "" ]; then
      echo_out "[Finish] mysqld options required for replay: $TOKUDB $ROCKSDB $MYEXTRA (the testcase will not reproduce the issue without these options passed to mysqld)"
    fi
    if [ -s $WORKO ]; then  # If there were no issues found, $WORKO was never written
      echo_out "[Finish] Final testcase size              : $SIZEF bytes ($LINECOUNTF lines)"
    fi
    echo_out "[Info] It is often beneficial to re-run reducer on the output file ($0 $WORKO) to make it smaller still (Reason for this is that certain lines may have been chopped up (think about missing end quotes or semicolons) resulting in non-reproducibility)"
    copy_workdir_to_tmp
  fi
  exit 0
}

copy_workdir_to_tmp(){
  WORKDIR_COPY_SUCCESS=0
  if [ "$MULTI_REDUCER" != "1" ]; then  # This is the parent/main reducer
    if [ $WORKDIR_LOCATION -eq 1 -o $WORKDIR_LOCATION -eq 2 ]; then
      echo_out "[Cleanup] Since tmpfs or ramfs (volatile memory) was used, reducer is now saving a copy of the work directory in /tmp/$EPOCH"
      echo_out "[Cleanup] Storing a copy of reducer ($0) and it's original input file ($INPUTFILE) in /tmp/$EPOCH also"
      if [[ $PXC_MOD -eq 1 || $GRP_RPL_MOD -eq 1 ]]; then
        sudo cp -a $WORKD /tmp/$EPOCH
        sudo chown -R `whoami`:`whoami` /tmp/$EPOCH
        cp $0 /tmp/$EPOCH  # Copy this reducer script
        cp $INPUTFILE /tmp/$EPOCH  # Copy the original input file
      else
        cp -a $WORKD /tmp/$EPOCH
        cp $0 /tmp/$EPOCH  # Copy this reducer script
        cp $INPUTFILE /tmp/$EPOCH  # Copy the original input file
      fi
      SPACE_WORKD=$(du -s $WORKD 2>/dev/null | sed 's|[ \t].*||')
      SPACE_TMPCP=$(du -s /tmp/$EPOCH 2>/dev/null | sed 's|[ \t].*||')
      if [ -d /tmp/$EPOCH -a ${SPACE_TMPCP} -gt ${SPACE_WORKD} ]; then
        WORKDIR_COPY_SUCCESS=1
        echo_out "[Cleanup] As reducer saved a copy of the work directory in /tmp/$EPOCH now deleting temporary work directory $WORKD"
        rm -Rf $WORKD
      else 
        echo_out "[Non-fatal Error] Reducer tried saving a copy of $WORKD, $INPUTFILE and $0 in /tmp/$EPOCH, but on checkup after the copy, either the target directory /tmp/$EPOCH was not found, or it's size was not larger then the original work directory $WORKD (which should not be the case, as $INPUTFILE and $0 were added unto it). Please check that the filesystem on which /tmp is stored is not full, and that this script has write rights to /tmp. Note this error is non-fatal, the original work directory $WORKD was left, and $INPUTFILE and $0, if necessary, can still be accessed from their original location."
      fi
    fi
  fi
}

report_linecounts(){
  if [ $MODE -ge 6 ]; then
    if [ "$STAGE" = "V" ]; then
      TXT_OUT="[Init] Initial number of lines in restructured input file(s):"
    else
      TXT_OUT="[Init] Number of lines in input file(s):"
    fi
    TS_LARGEST_WORKF_LINECOUNT=0
    for t in $(eval echo {1..$TS_THREADS}); do 
      TS_WORKF_NAME=$(eval echo $(echo '$WORKF'"$t"))
      export TS_LINECOUNTF$t=$(cat $TS_WORKF_NAME | wc -l | tr -d '[\t\n ]*')
      TS_WORKF_LINECOUNT=$(eval echo $(echo '$TS_LINECOUNTF'"$t"))
      TXT_OUT="$TXT_OUT #$t: $TS_WORKF_LINECOUNT"
      if [ $TS_WORKF_LINECOUNT -gt $TS_LARGEST_WORKF_LINECOUNT ]; then TS_LARGEST_WORKF_LINECOUNT=$TS_WORKF_LINECOUNT; fi
    done
    echo_out "$TXT_OUT"
  else
    LINECOUNTF=`cat $WORKF | wc -l | tr -d '[\t\n ]*'`
    if [ "$STAGE" = "V" ]; then
      echo_out "[Init] Initial number of lines in restructured input file: $LINECOUNTF"
    else
      echo_out "[Init] Number of lines in input file: $LINECOUNTF"
    fi
  fi
  if [ "$STAGE" = "V" ]; then echo_out "[Info] Linecounts for restructured files are usually higher as INSERT lines are broken up etc."; fi
}

verify_not_found(){
  if [ "$MULTI_REDUCER" != "1" ]; then  # This is the parent - change pathnames to reflect that issue was in a subreducer
    EXTRA_PATH="subreducer/<nr>/"
  else
    EXTRA_PATH=""
  fi
  echo_out "$ATLEASTONCE [Stage $STAGE] Initial verify of the issue: fail. Bug/issue is not present. Terminating."
  echo_out "[Finish] Verification failed. It may help to check the following files to get an idea as to why this run did not reproduce the issue (if these files do not give any further hints, please check variable/initialization differences, enviroment differences etc.):"
  WORKDIR_COPY_SUCCESS=0  # Defensive programming, not required (as copy_workdir_to_tmp sets it)
  copy_workdir_to_tmp
  if [ $WORKDIR_COPY_SUCCESS -eq 0 ]; then 
    PRINTWORKD="$WORKD"
  else
    PRINTWORKD="/tmp/${EPOCH}"
  fi
  if [ $MODE -ge 6 ]; then
    if [ $TS_DBG_CLI_OUTPUT -eq 1 ]; then
      echo_out "[Finish] mysql CLI client output : ${PRINTWORKD}/${EXTRA_PATH}mysql<threadid>.out   (Look for clear signs of non-replay or a terminated connection)"
    else
      echo_out "[Finish] mysql CLI client output : not recorded                 (You may want to *TEMPORARY* turn on TS_DBG_CLI_OUTPUT to debug. Ensure to turn it back off before re-testing if the issue exists as it will likely not show with debug on if this is a multi-threaded issue)"
     fi
  else
    if [ $PQUERY_MOD -eq 1 ]; then
      echo_out "[Finish] pquery client output    : ${PRINTWORKD}/{EXTRA_PATH}default.node.tld_thread-0.sql  (Look for clear signs of non-replay or a terminated connection)"
    elset
      echo_out "[Finish] mysql CLI client output : ${PRINTWORKD}/${EXTRA_PATH}mysql.out             (Look for clear signs of non-replay or a terminated connection)"
    fi
  fi
  if [ $MODE -eq 1 -o $MODE -eq 6 ]; then
    echo_out "[Finish] Valgrind output         : ${PRINTWORKD}/${EXTRA_PATH}valgrind.out          (Check if there are really 0 errors)"
  fi
  echo_out "[Finish] mysqld error log output : ${PRINTWORKD}/${EXTRA_PATH}error.log(.out)       (Check if the mysqld server output looks normal. ".out" = last startup)"
  echo_out "[Finish] initialization output   : ${PRINTWORKD}/${EXTRA_PATH}init.log              (Check if the inital server initalization happened correctly)"
  echo_out "[Finish] time init output        : ${PRINTWORKD}/${EXTRA_PATH}timezone.init         (Check if the timezone information was installed correctly)"
  exit 1
}

verify(){
  #STAGEV: VERIFY: Check first if the bug/issue exists and is reproducible by reducer
  STAGE='V'
  TRIAL=1
  echo_out "$ATLEASTONCE [Stage $STAGE] Verifying the bug/issue exists and is reproducible by reducer (duration depends on initial input file size)"
  # --init-file: Instead of using an init file, add the init file contents to the top of the testcase, if that still reproduces the issue, below
  ORIGINALMYEXTRA=$MYEXTRA
  INITFILE=
  MYEXTRAWITHOUTINIT=
  if [[ "$MYEXTRA" == *"init_file"* || "$MYEXTRA" == *"init-file"* ]]; then
    INITFILE=$(echo $MYEXTRA | grep -E -oE "\-\-init[-_]file=[^ ]+" | sed 's|\-\-init[-_]file=||')
    MYEXTRAWITHOUTINIT=$(echo $MYEXTRA | sed 's|\-\-init[-_]file=[^ ]\+||')
  fi
  if [ "$MULTI_REDUCER" != "1" ]; then  # This is the parent/main reducer 
    while :; do
      multi_reducer $1
      if [ "$?" -ge "1" ]; then  # Verify success.
        if [ $MODE -lt 6 ]; then
          # At the moment, MODE6+ does not use initial simplification yet. And, since MODE6+ swaps to MODE1+ after succesfull thread elimination,
          # multi_reducer_decide_input is only skipped when 1) there is a multi-threaded testcase and 2) this testcase could not be reducerd to a single thread
          # This is because (after a succesfull thread elimination process, the verify stage is re-run in a MODE1+)
          # However, for full multi-threaded simplification, reducer needs to do this: thread elimination > DATA thread reducing+SQL. Then, reducer will need 
          # to have a VERIFY for the initial simplification of the data thread (and this is how multi-threaded simplification should start)
          multi_reducer_decide_input
        fi
        report_linecounts
        break
      fi
      echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] As (possibly sporadic) issue did not reproduce with $MULTI_THREADS threads, now increasing number of threads to $[$MULTI_THREADS+MULTI_THREADS_INCREASE] (maximum is $MULTI_THREADS_MAX)"
      MULTI_THREADS=$[$MULTI_THREADS+MULTI_THREADS_INCREASE]
      if [ $MULTI_THREADS -gt $MULTI_THREADS_MAX ]; then  # Verify failed. Terminate.
        verify_not_found
      elif [ $MULTI_THREADS -ge 35 ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] WARNING: High load active. You may start seeing messages releated to server overload like:"
        echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] WARNING: 'command not found', 'No such file or directory' or 'fork: retry: Resource temporarily unavailable'"
        echo_out "$ATLEASTONCE [Stage $STAGE] [MULTI] WARNING: These can safely be ignored, reducer is trying to see if the issue can be reproduced at all"
      fi
    done
  else  # This is a subreducer: go through normal verification stages
    while :; do
      if   [ $TRIAL -eq 1 ]; then
        if [ $MODE -ge 6 ]; then
          echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #1: Maximum initial simplification & DEBUG_SYNC disabled and removed (DEBUG_SYNC may not be necessary)"
          for t in $(eval echo {1..$TS_THREADS}); do 
            export TS_WORKF=$(eval echo $(echo '$WORKF'"$t"))
            export TS_WORKT=$(eval echo $(echo '$WORKT'"$t"))
            grep -E --binary-files=text -v "^#|^$|DEBUG_SYNC" $TS_WORKF \
              | sed -e 's/[\t ]\+/ /g' \
              | sed -e "s/[ ]*)[ ]*,[ ]*([ ]*/),\n(/g" \
              | sed -e "s/;\(.*CREATE.*TABLE\)/;\n\1/g" \
              | sed -e "/CREATE.*TABLE.*;/s/(/(\n/1;/CREATE.*TABLE.*;/s/\(.*\))/\1\n)/;/CREATE.*TABLE.*;/s/,/,\n/g;" \
              | sed -e 's/ VALUES[ ]*(/ VALUES \n(/g' \
                    -e "s/', '/','/g" > $TS_WORKT
          done
        else
          echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #1: Maximum initial simplification & cleanup"
          grep -E --binary-files=text -v "^#|^$|DEBUG_SYNC|^\-\-| \[Note\] |====|  WARNING: |^Hope that|^Logging: |\++++| exit with exit status |Lost connection to | valgrind |Using [MSI]|Using dynamic|MySQL Version|\------|TIME \(ms\)$|Skipping ndb|Setting mysqld |Binaries are debug |Killing Possible Leftover|Removing Stale Files|Creating Directories|Installing Master Database|Servers started, |Try: yum|Missing separate debug|SOURCE|CURRENT_TEST|\[ERROR\]|with SSL|_root_|connect to MySQL|No such file|is deprecated at|just omit the defined" $WORKF \
            | sed -e 's/;[\t ]*#.*/;/i' \
            | sed -e 's/[\t ]\+/ /g' \
            | sed -e 's/Query ([0-9a-fA-F]): \(.*\)/\1;/g' \
            | sed -e "s/[ ]*)[ ]*,[ ]*([ ]*/),\n(/g" \
            | sed -e "s/;\(.*CREATE.*TABLE\)/;\n\1/g" \
            | sed -e "/CREATE.*TABLE.*;/s/(/(\n/1;/CREATE.*TABLE.*;/s/\(.*\))/\1\n)/;/CREATE.*TABLE.*;/s/,/,\n/g;" \
            | sed -e 's/ VALUES[ ]*(/ VALUES \n(/g' \
                  -e "s/', '/','/g" > $WORKT
          if [ "${INITFILE}" != "" ]; then  # Instead of using an init file, add the init file contents to the top of the testcase
            echo_out "$ATLEASTONCE [Stage $STAGE] Adding contents of --init-file directly into testcase and removing --init-file option from MYEXTRA"
            echo "$(echo "$DROPC";cat $INITFILE;cat $WORKT | grep -E --binary-files=text -v "$DROPC")" > $WORKT
            MYEXTRA=$MYEXTRAWITHOUTINIT
            echo $MYEXTRA > $WORKD/MYEXTRA
          fi
        fi
      elif [ $TRIAL -eq 2 ]; then
        if [ $MODE -ge 6 ]; then
          echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #2: Medium initial simplification (CREATE+INSERT lines split) & DEBUG_SYNC disabled and removed"
          for t in $(eval echo {1..$TS_THREADS}); do 
            export TS_WORKF=$(eval echo $(echo '$WORKF'"$t"))
            export TS_WORKT=$(eval echo $(echo '$WORKT'"$t"))
            sed -e "s/[\t ]*)[\t ]*,[\t ]*([\t ]*/),\n(/g" TS_$WORKF \
              | sed -e "s/;\(.*CREATE.*TABLE\)/;\n\1/g" \
              | sed -e "/CREATE.*TABLE.*;/s/(/(\n/1;/CREATE.*TABLE.*;/s/\(.*\))/\1\n)/;/CREATE.*TABLE.*;/s/,/,\n/g;" > $TS_WORKT
          done
        else
          echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #2: High initial simplification & cleanup (no RQG log text removal)"
          grep -E --binary-files=text -v "^#|^$|DEBUG_SYNC|^\-\-" $WORKF \
            | sed -e 's/;[\t ]*#.*/;/i' \
            | sed -e 's/[\t ]\+/ /g' \
            | sed -e "s/[ ]*)[ ]*,[ ]*([ ]*/),\n(/g" \
            | sed -e "s/;\(.*CREATE.*TABLE\)/;\n\1/g" \
            | sed -e "/CREATE.*TABLE.*;/s/(/(\n/1;/CREATE.*TABLE.*;/s/\(.*\))/\1\n)/;/CREATE.*TABLE.*;/s/,/,\n/g;" \
            | sed -e 's/ VALUES[ ]*(/ VALUES \n(/g' \
                  -e "s/', '/','/g" > $WORKT
          if [ "${INITFILE}" != "" ]; then  # Instead of using an init file, add the init file contents to the top of the testcase
            echo_out "$ATLEASTONCE [Stage $STAGE] Adding contents of --init-file directly into testcase and removing --init-file option from MYEXTRA"
            echo "$(echo "$DROPC";cat $INITFILE;cat $WORKT | grep -E --binary-files=text -v "$DROPC")" > $WORKT
            MYEXTRA=$MYEXTRAWITHOUTINIT
            echo $MYEXTRA > $WORKD/MYEXTRA
          fi
        fi
      elif [ $TRIAL -eq 3 ]; then
        if [ $MODE -ge 6 ]; then
        TS_DEBUG_SYNC_REQUIRED_FLAG=1
        echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #3: Maximum initial simplification & DEBUG_SYNC enabled"
          for t in $(eval echo {1..$TS_THREADS}); do 
            export TS_WORKF=$(eval echo $(echo '$WORKF'"$t"))
            export TS_WORKT=$(eval echo $(echo '$WORKT'"$t"))
            grep -E --binary-files=text -v "^#|^$" $TS_WORKF \
              | sed -e 's/[\t ]\+/ /g' \
              | sed -e "s/[ ]*)[ ]*,[ ]*([ ]*/),\n(/g" \
              | sed -e "s/;\(.*CREATE.*TABLE\)/;\n\1/g" \
              | sed -e "/CREATE.*TABLE.*;/s/(/(\n/1;/CREATE.*TABLE.*;/s/\(.*\))/\1\n)/;/CREATE.*TABLE.*;/s/,/,\n/g;" \
              | sed -e 's/ VALUES[ ]*(/ VALUES \n(/g' \
                    -e "s/', '/','/g" > $TS_WORKT
          done
        else
          echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #3: High initial simplification (no RQG text removal & less cleanup)"
          grep -E --binary-files=text -v "^#|^$|DEBUG_SYNC|^\-\-" $WORKF \
            | sed -e 's/;[\t ]*#.*/;/i' \
            | sed -e "s/[\t ]*)[\t ]*,[\t ]*([\t ]*/),\n(/g" \
            | sed -e "s/;\(.*CREATE.*TABLE\)/;\n\1/g" \
            | sed -e "/CREATE.*TABLE.*;/s/(/(\n/1;/CREATE.*TABLE.*;/s/\(.*\))/\1\n)/;/CREATE.*TABLE.*;/s/,/,\n/g;" \
            | sed -e 's/ VALUES[ ]*(/ VALUES \n(/g' > $WORKT
          if [ "${INITFILE}" != "" ]; then  # Instead of using an init file, add the init file contents to the top of the testcase
            echo_out "$ATLEASTONCE [Stage $STAGE] Adding contents of --init-file directly into testcase and removing --init-file option from MYEXTRA"
            echo "$(echo "$DROPC";cat $INITFILE;cat $WORKT | grep -E --binary-files=text -v "$DROPC")" > $WORKT
            MYEXTRA=$MYEXTRAWITHOUTINIT
            echo $MYEXTRA > $WORKD/MYEXTRA
          fi
        fi
      elif [ $TRIAL -eq 4 ]; then
        if [ $MODE -ge 6 ]; then
          echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #4: Medium initial simplification (CREATE+INSERT lines split) & DEBUG_SYNC enabled"
          for t in $(eval echo {1..$TS_THREADS}); do 
            export TS_WORKF=$(eval echo $(echo '$WORKF'"$t"))
            export TS_WORKT=$(eval echo $(echo '$WORKT'"$t"))
            sed -e "s/[\t ]*)[\t ]*,[\t ]*([\t ]*/),\n(/g" TS_$WORKF \
              | sed -e "s/;\(.*CREATE.*TABLE\)/;\n\1/g" \
              | sed -e "/CREATE.*TABLE.*;/s/(/(\n/1;/CREATE.*TABLE.*;/s/\(.*\))/\1\n)/;/CREATE.*TABLE.*;/s/,/,\n/g;" > $TS_WORKT
          done
        else
          echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #4: Medium initial simplification (CREATE+INSERT lines split & remove # comments)"
          sed -e "s/[\t ]*)[\t ]*,[\t ]*([\t ]*/),\n(/g" $WORKF \
            | sed -e 's/;[\t ]*#.*/;/i' \
            | sed -e "s/;\(.*CREATE.*TABLE\)/;\n\1/g" \
            | sed -e "/CREATE.*TABLE.*;/s/(/(\n/1;/CREATE.*TABLE.*;/s/\(.*\))/\1\n)/;/CREATE.*TABLE.*;/s/,/,\n/g;" > $WORKT
          if [ "${INITFILE}" != "" ]; then  # Instead of using an init file, add the init file contents to the top of the testcase
            echo_out "$ATLEASTONCE [Stage $STAGE] Adding contents of --init-file directly into testcase and removing --init-file option from MYEXTRA"
            echo "$(echo "$DROPC";cat $INITFILE;cat $WORKT | grep -E --binary-files=text -v "$DROPC")" > $WORKT
            MYEXTRA=$MYEXTRAWITHOUTINIT
            echo $MYEXTRA > $WORKD/MYEXTRA
          fi
        fi
      elif [ $TRIAL -eq 5 ]; then
        if [ $MODE -ge 6 ]; then
          echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #5: Low initial simplification (only main data INSERT lines split) & DEBUG_SYNC enabled"
          for t in $(eval echo {1..$TS_THREADS}); do 
            export TS_WORKF=$(eval echo $(echo '$WORKF'"$t"))
            export TS_WORKT=$(eval echo $(echo '$WORKT'"$t"))
            sed -e "s/[\t ]*)[\t ]*,[\t ]*([\t ]*/),\n(/g" $TS_WORKF > $TS_WORKT
          done
        else
          # The benefit of splitting INSERT lines: example: INSERT (a),(b),(c); becomes INSERT (a),\n(b)\n(c); and thus the seperate line with "b" could be eliminated/simplified. 
          # If the testcase then works fine withouth the 'b' elemeneted inserted, it has become simpler. Consider large inserts (100's of rows) and how complexity can be reduced.
          echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #5: Low initial simplification (only main data INSERT lines split & remove # comments)"
          sed -e "s/[\t ]*)[\t ]*,[\t ]*([\t ]*/),\n(/g" $WORKF \
            | sed -e 's/;[\t ]*#.*/;/i' > $WORKT
          if [ "${INITFILE}" != "" ]; then  # Instead of using an init file, add the init file contents to the top of the testcase
            echo_out "$ATLEASTONCE [Stage $STAGE] Adding contents of --init-file directly into testcase and removing --init-file option from MYEXTRA"
            echo "$(echo "$DROPC";cat $INITFILE;cat $WORKT | grep -E --binary-files=text -v "$DROPC")" > $WORKT
            MYEXTRA=$MYEXTRAWITHOUTINIT
            echo $MYEXTRA > $WORKD/MYEXTRA
          fi
        fi
      elif [ $TRIAL -eq 6 ]; then
        if [ $MODE -ge 6 ]; then
          echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #6: No initial simplification & DEBUG_SYNC enabled"
          for t in $(eval echo {1..$TS_THREADS}); do 
            export TS_WORKF=$(eval echo $(echo '$WORKF'"$t"))
            export TS_WORKT=$(eval echo $(echo '$WORKT'"$t"))
            cp -f $TS_WORKF $TS_WORKT
          done
        else
          echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #6: No initial simplification"
          echo_out "$ATLEASTONCE [Stage $STAGE] Restoring original MYEXTRA and using --init-file exactly as given there originally"
          MYEXTRA=$ORIGINALMYEXTRA
          echo $MYEXTRA > $WORKD/MYEXTRA
          cp -f $WORKF $WORKT
        fi
      else
        verify_not_found
      fi 
      run_and_check
      if [ "$?" -eq "1" ]; then  # Verify success, exit loop
        echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #$TRIAL: Success. Issue detected. Saved files."
        report_linecounts
        break
      else  # Verify fail, 'while' loop continues
        echo_out "$ATLEASTONCE [Stage $STAGE] Verify attempt #$TRIAL: Failed. Issue not detected."
        TRIAL=$[$TRIAL+1]
      fi
    done
  fi
}

#Init
  set_internal_options  # Should come before options_check
  options_check $1
  if [ "$MULTI_REDUCER" != "1" ]; then  # This is a parent/main reducer
    init_empty_port
  fi
  init_workdir_and_files
  if [ $MODE -eq 9 ]; then echo_out "[Init] Run mode: MODE=9: ThreadSync Crash [ALPHA]"
                           echo_out "[Init] Looking for any mysqld crash"; fi
  if [ $MODE -eq 8 ]; then echo_out "[Init] Run mode: MODE=8: ThreadSync mysqld error log [ALPHA]"
                           echo_out "[Init] Looking for this string: '$TEXT' in mysqld error log output (@ $WORKD/error.log.out when MULTI mode is not active)"; fi
  if [ $MODE -eq 7 ]; then echo_out "[Init] Run mode: MODE=7: ThreadSync mysql CLI output [ALPHA]"
                           echo_out "[Init] Looking for this string: '$TEXT' in mysql CLI output (@ $WORKD/mysql.out when MULTI mode is not active)"; fi
  if [ $MODE -eq 6 ]; then echo_out "[Init] Run mode: MODE=6: ThreadSync Valgrind output [ALPHA]"
                           echo_out "[Init] Looking for this string: '$TEXT' in Valgrind output (@ $WORKD/valgrind.out when MULTI mode is not active)"; fi
  if [ $MODE -eq 5 ]; then echo_out "[Init] Run mode: MODE=5: MTR testcase output"
                           echo_out "[Init] Looking for "$MODE5_COUNTTEXT"x this string: '$TEXT' in mysql CLI verbose output (@ $WORKD/mysql.out when MULTI mode is not active)"
    if [ "$MODE5_ADDITIONAL_TEXT" != "" -a $MODE5_ADDITIONAL_COUNTTEXT -ge 1 ]; then 
                           echo_out "[Init] Looking additionally for "$MODE5_ADDITIONAL_COUNTTEXT"x this string: '$MODE5_ADDITIONAL_TEXT' in mysql CLI verbose output (@ $WORKD/mysql.out when MULTI mode is not active)"; fi; fi
  if [ $MODE -eq 4 ]; then 
    if [ $REDUCE_GLIBC_OR_SS_CRASHES -gt 0 ]; then
                           echo_out "[Init] Run mode: MODE=4: GLIBC crash"
                           echo_out "[Init] Looking for any GLIBC crash"; 
    else
                           echo_out "[Init] Run mode: MODE=4: Crash"
                           echo_out "[Init] Looking for any mysqld crash"; fi; fi
  if [ $MODE -eq 3 ]; then
    if [ $REDUCE_GLIBC_OR_SS_CRASHES -gt 0 ]; then
                           echo_out "[Init] Run mode: MODE=3 with REDUCE_GLIBC_OR_SS_CRASHES=1: console typscript log"
                           echo_out "[Init] Looking for this string: '$TEXT' in console typscript log output (@ /tmp/reducer_typescript${TYPESCRIPT_UNIQUE_FILESUFFIX}.log)";
    elif [ $USE_TEXT_STRING -gt 0 ]; then
                           echo_out "[Init] Run mode: MODE=3 with USE_TEXT_STRING=1: text_string.sh against mysqld error log"   
                           echo_out "[Init] Looking for this string: '$TEXT' in text_string.sh error_log output (@ $WORKD/error.log.out.text_string when MULTI mode is not active)"; 
    else
                           echo_out "[Init] Run mode: MODE=3: mysqld error log"   
                           echo_out "[Init] Looking for this string: '$TEXT' in mysqld error log output (@ $WORKD/error.log.out when MULTI mode is not active)"; fi; fi
  if [ $MODE -eq 2 ]; then 
    if [ $PQUERY_MOD -eq 1 ]; then 
                           echo_out "[Init] Run mode: MODE=2: pquery client output"
                           echo_out "[Init] Looking for this string: '$TEXT' in pquery client output (@ $WORKD/default.node.tld_thread-0.sql when MULTI mode is not active)";
    else
                           echo_out "[Init] Run mode: MODE=2: mysql CLI output"
                           echo_out "[Init] Looking for this string: '$TEXT' in mysql CLI output (@ $WORKD/mysql.out when MULTI mode is not active)"; fi; fi 
  if [ $MODE -eq 1 ]; then echo_out "[Init] Run mode: MODE=1: Valgrind output"
                           echo_out "[Init] Looking for this string: '$TEXT' in Valgrind output (@ $WORKD/valgrind.out when MULTI mode is not active)"; fi
  if [ $MODE -eq 0 ]; then echo_out "[Init] Run mode: MODE=0: Timeout/hang"
                           echo_out "[Init] Looking for trial durations longer then ${TIMEOUT_CHECK_REAL} seconds (with timeout trigger @ ${TIMEOUT_CHECK} seconds)"; fi
  echo_out "[Info] Leading [] = No bug/issue found yet | [*] = Bug/issue at least seen once"
  report_linecounts
  if [ "$SKIPV" != "1" ]; then
    verify $1
    if [ "$MULTI_REDUCER" = "1" ]; then
      # This is a simplfication subreducer started by a parent/main reducer, but only to verify if the issue is reproducible (as SKIPV=0).
      # We terminate now after checking if the issue is yes/no reproducible.
      finish $INPUTFILE
    fi
  fi

#STAGET: TS_THREAD_ELIMINATION: Reduce the number of threads in MODE9 (ThreadSync multi-threaded testcases)
if [ $MODE -ge 6 ]; then
  NEXTACTION="& try removing next thread"
  STAGE=T
  TRIAL=1
  if [ $TS_THREADS -ne 1 ]; then  # If $TS_THREADS = 1 there is only one thread, and thread elimination is not necessary
    echo_out "$ATLEASTONCE [Stage $STAGE] ThreadSync thread elimination: removing unncessary threads"
    while :; do
      for t in $(eval echo {1..$TS_THREADS}); do 
        export TS_WORKF=$(eval echo $(echo '$WORKF'"$t"))
        export TS_WORKT=$(eval echo $(echo '$WORKT'"$t"))
        cp -f $TS_WORKF $TS_WORKT
      done

      if [ $TRIAL -gt 1 ]; then report_linecounts; fi
      TS_ELIMINATION_THREAD_ID=$[$TS_THREADS+1+$TS_ELIMINATED_THREAD_COUNT-$TRIAL]
      if [ $SPORADIC -eq 0 ]; then 
        if   [ $TS_LARGEST_WORKF_LINECOUNT -gt 40000 ]; then TS_TE_ATTEMPTS=1 # Large   case, highly likely not sporadic, try only once to eliminate a thread 
        elif [ $TS_LARGEST_WORKF_LINECOUNT -gt 10000 ]; then TS_TE_ATTEMPTS=2 # Medium  case, highly likely not sporadic, try twice to eliminate a thread
        elif [ $TS_LARGEST_WORKF_LINECOUNT -gt  5000 ]; then TS_TE_ATTEMPTS=4 # Small   case, highly likely not sporadic, try 4 times to eliminate a thread
        elif [ $TS_LARGEST_WORKF_LINECOUNT -gt  1000 ]; then TS_TE_ATTEMPTS=6 # Smaller case, highly likely not sporadic, try 6 times to eliminate a thread
        else TS_TE_ATTEMPTS=10                                                # Minimal case, highly likely not sporadic, try 10 times to eliminate a thread
        fi
      else
        if   [ $TS_LARGEST_WORKF_LINECOUNT -gt 40000 ]; then TS_TE_ATTEMPTS=10 # Large   case, established sporadic, try 10 thread elimination attempts
        elif [ $TS_LARGEST_WORKF_LINECOUNT -gt 10000 ]; then TS_TE_ATTEMPTS=13 # Medium  case, established sporadic, try 13 times to eliminate a thread
        elif [ $TS_LARGEST_WORKF_LINECOUNT -gt  5000 ]; then TS_TE_ATTEMPTS=15 # Small   case, established sporadic, try 15 to eliminate a thread
        elif [ $TS_LARGEST_WORKF_LINECOUNT -gt  1000 ]; then TS_TE_ATTEMPTS=15 # Smaller case, established sporadic, try 17 to eliminate a thread
        else TS_TE_ATTEMPTS=20                                                 # Minimal case, established sporadic, try 20 times to eliminate a thread
        fi
      fi
      for a in $(eval echo {1..$TS_TE_ATTEMPTS}); do 
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Attempt $a] Trying to eliminate thread $TS_ELIMINATION_THREAD_ID"

        # Single thread elimination (based on reverse order of TRIAL - control thread is normally first)
        export TS_WORKF=$(eval echo $(echo '$WORKF'"$TS_ELIMINATION_THREAD_ID"))
        export TS_WORKT=$(eval echo $(echo '$WORKT'"$TS_ELIMINATION_THREAD_ID"))
        TS_T_THREAD=$(grep -E "DEBUG_SYNC.*SIGNAL" $TS_WORKF | sed -e 's/^.*SIGNAL[ ]*//;s/ .*$//g')
        echo "" > $TS_WORKT

        # Update the control thread (remove DEBUG_SYNCs for thread in question)
        if [ -n "$TS_T_THREAD" ]; then  # Don't run this for threads which did not have DEBUG_SYNC text yet (early crash) 
                                        # This does leave some unnecessary DEBUG_SYNC info in the control thread, but this will be auto-reduced later
          for t in $(eval echo {1..$TS_THREADS}); do
            export TS_WORKF=$(eval echo $(echo '$WORKF'"$t"))
            export TS_WORKT=$(eval echo $(echo '$WORKT'"$t"))
            if grep -E --binary-files=text -qi "SIGNAL GO_T2" $TS_WORKF; then  # Control thread
              grep -E --binary-files=text -v "DEBUG_SYNC.*$TS_T_THREAD " $TS_WORKF > $TS_WORKT  # do not remove critical end space (T2 == T20 delete otherwise!)
            fi
          done
        fi
        run_and_check
        if [ "$?" -eq "1" ]; then  # Thread elimination success
          echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Attempt $a] Thread $TS_ELIMINATION_THREAD_ID elimination: Success. Thread $TS_ELIMINATION_THREAD_ID was eliminated and input file(s) were swapped"
          break
        else
          if [ $a -eq $TS_TE_ATTEMPTS ]; then
            echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Attempt $a] Thread $TS_ELIMINATION_THREAD_ID elimination: Failed. Thread $TS_ELIMINATION_THREAD_ID will be left as-is ftm (will be reduced later)."
          else
            echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Attempt $a] Thread $TS_ELIMINATION_THREAD_ID elimination: Failed. Re-attempting."
          fi
          # Re-instate TS_WORKT with original contents
          cp -f $TS_WORKF $TS_WORKT
        fi
      done
      TRIAL=$[$TRIAL+1]
      if [ $TRIAL -eq $[$TS_THREADS+1+$TS_ELIMINATED_THREAD_COUNT] ]; then 
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Last thread processed. ThreadSync thread elimination complete"
        break
      fi
    done
  fi
  if [ $TS_THREADS -eq 1 ]; then
    echo_out "$ATLEASTONCE [Stage $STAGE] [TSE Finish] Only one SQL thread remaining. Merging DATA and SQL thread and swapping to single threaded simplification"
    WORKO="$WORKD/single_out.sql"
    cp -f $TS_DATAINPUTFILE $WORKF
    # We can immediately use thread #1 as TS_init_all_sql_files (from the last run above, or from the original run if there was ever only one thread) 
    # has set thread #1 to be the correct remaining thread
    export TS_WORKF=$(eval echo $(echo '$WORKF1')); cat $TS_WORKF >> $WORKF
    cp -f $WORKF $WORKO
    echo_out "$ATLEASTONCE [Stage $STAGE] [TSE Finish] Merging complete. Single threaded DATA+SQL file saved as $WORKO"
    if [ $MODE -eq 6 ]; then
      export -n MODE=1
      echo_out "$ATLEASTONCE [Stage $STAGE] [TSE Finish] Swapped to standard single-threaded valgrind output testing (MODE1)"
    elif [ $MODE -eq 7 ]; then
      export -n MODE=2
      echo_out "$ATLEASTONCE [Stage $STAGE] [TSE Finish] Swapped to standard single-threaded mysql CLI output testing (MODE2)"
    elif [ $MODE -eq 8 ]; then
      export -n MODE=3
      echo_out "$ATLEASTONCE [Stage $STAGE] [TSE Finish] Swapped to standard single-threaded mysqld output simplification (MODE3)"
    elif [ $MODE -eq 9 ]; then 
      export -n MODE=4
      echo_out "$ATLEASTONCE [Stage $STAGE] [TSE Finish] Swapped to standard single-threaded crash simplification (MODE4)"
    fi 
    VERIFY=1
    echo_out "$ATLEASTONCE [Stage $STAGE] [TSE Finish] Now starting re-verification in $MODE (this enables INSERT splitting in initial simplification etc.)"
    verify $WORKO
  else
    echo_out "$ATLEASTONCE [Stage $STAGE] [TSE Finish] More than one thread remaining. Implement multi-threaded simplification here"
    echo "Terminating now."
    exit 1 
  fi
fi

#STAGE1: Reduce large size files fast
LINECOUNTF=`cat $WORKF | wc -l | tr -d '[\t\n ]*'`
if [ $SKIPSTAGEBELOW -lt 1 -a $SKIPSTAGEABOVE -gt 1 ]; then
  NEXTACTION="& try removing next random line(set)"
  STAGE=1
  TRIAL=1
  if [ $LINECOUNTF -ge $STAGE1_LINES -o $PQUERY_MULTI -gt 0 -o $FORCE_SKIPV -gt 0 -o $REDUCE_GLIBC_OR_SS_CRASHES -gt 0 ]; then
    echo_out "$ATLEASTONCE [Stage $STAGE] Now executing first trial in stage $STAGE (duration depends on initial input file size)"
    while [ $LINECOUNTF -ge $STAGE1_LINES ]; do 
      if [ $LINECOUNTF -eq $STAGE1_LINES  ]; then NEXTACTION="& Progress to the next stage"; fi
      if [ $TRIAL -gt 1 ]; then echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Remaining number of lines in input file: $LINECOUNTF"; fi 
      if [ "$MULTI_REDUCER" != "1" -a $SPORADIC -eq 1 -a $REDUCE_GLIBC_OR_SS_CRASHES -le 0 ]; then  
        # This is the parent/main reducer AND the issue is sporadic (so; need to use multiple threads). Disabled for REDUCE_GLIBC_OR_SS_CRASHES as it is always single-threaded
        multi_reducer $WORKF  # $WORKT is not used by the main reducer in this case. The subreducer uses $WORKT it's own session however (in the else below) 
      else
        determine_chunk
        cut_random_chunk
        run_and_check
      fi
      TRIAL=$[$TRIAL+1]
      LINECOUNTF=`cat $WORKF | wc -l | tr -d '[\t\n ]*'`
    done
  else 
    echo_out "$ATLEASTONCE [Stage $STAGE] Skipping stage $STAGE as remaining number of lines in input file <= $STAGE1_LINES"
  fi
fi

#STAGE2: Loop through each line of the remaining file (now max $STAGE1_LINES lines) once 
if [ $SKIPSTAGEBELOW -lt 2 -a $SKIPSTAGEABOVE -gt 2 ]; then
  NEXTACTION="& try removing next line in the file"
  STAGE=2
  TRIAL=1
  NOISSUEFLOW=0
  LINES=`cat $WORKF | wc -l | tr -d '[\t\n ]*'`
  CURRENTLINE=2 # Do not filter first line which contains DROP/CREATE/USE of test db
  REALLINE=2
  echo_out "$ATLEASTONCE [Stage $STAGE] Now executing first trial in stage $STAGE"
  while [ $LINES -ge $REALLINE ]; do
    if [ $LINES -eq $REALLINE  ]; then NEXTACTION="& progress to the next stage"; fi
    if [ $TRIAL -gt 1 ]; then echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Remaining number of lines in input file: $LINECOUNTF"; fi 
    cut_fixed_chunk 
    run_and_check
    if [ $? -eq 0 ]; then CURRENTLINE=$[$CURRENTLINE+1]; fi  # Only advance the column number if there was no issue, otherwise stay on the same column (An issue will remove the current column and shift all other columns down by one, hence you have to stay in the same place as it will contain the next column)
    REALLINE=$[$REALLINE+1]
    TRIAL=$[$TRIAL+1]
    SIZEF=`stat -c %s $WORKF`
    LINECOUNTF=`cat $WORKF | wc -l | tr -d '[\t\n ]*'`
  done
fi

#STAGE3: Execute various cleanup sed's to reduce testcase complexity further. Perform a check if the issue is still present for each replacement (set)
if [ $SKIPSTAGEBELOW -lt 3 -a $SKIPSTAGEABOVE -gt 3 ]; then
  STAGE=3
  TRIAL=1
  SIZEF=`stat -c %s $WORKF`
  echo_out "$ATLEASTONCE [Stage $STAGE] Now executing first trial in stage $STAGE"
  while :; do
    NEXTACTION="& try next testcase complexity reducing sed"
    NOSKIP=0
  
    # The @##@ sed's remove comments like /*! NULL */. Each sed removes one /* */ block per line, so 3 sed's removes 3x /* */ for each line
    if   [ $TRIAL -eq 1  ]; then sed -e "s/[\t ]*,[ \t]*/,/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 2  ]; then sed -e "s/\\\'//g" $WORKF > $WORKT
    elif [ $TRIAL -eq 3  ]; then sed -e "s/'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'/'0000-00-00'/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 4  ]; then sed -e "s/'[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9][0-9][0-9][0-9][0-9][0-9]'/'00:00:00.000000'/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 5  ]; then sed -e "s/'[-][0-9]*\.[0-9]*'/'0.0'/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 6  ]; then sed -e "s/'[0-9][0-9]:[0-9][0-9]:[0-9][0-9]'/'00:00:00'/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 7  ]; then sed -e "s/'[-][0-9]'/'0'/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 8  ]; then sed -e "s/'[-][0-9]\+'/'0'/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 9  ]; then sed -e "s/'0'/0/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 10 ]; then sed -e "s/,[-][0-9],/,0,/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 11 ]; then sed -e "s/,[-][0-9]\+,/,0,/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 12 ]; then sed -e "s/'[a-z]'/'a'/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 13 ]; then sed -e "s/'[a-z]\+'/'a'/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 14 ]; then sed -e "s/'[A-Z]'/'a'/g"  $WORKF > $WORKT
    elif [ $TRIAL -eq 15 ]; then sed -e "s/'[A-Z]\+'/'a'/g"  $WORKF > $WORKT
    elif [ $TRIAL -eq 16 ]; then sed -e 's/^[ \t]\+//g' -e 's/[ \t]\+$//g' -e 's/[ \t]\+/ /g' $WORKF > $WORKT
    elif [ $TRIAL -eq 17 ]; then sed -e 's/( /(/g' -e 's/ )/)/g' $WORKF > $WORKT
    elif [ $TRIAL -eq 18 ]; then sed -e 's/\*\//@##@/' -e 's/\/\*.*@##@//' $WORKF > $WORKT
    elif [ $TRIAL -eq 19 ]; then sed -e 's/\*\//@##@/' -e 's/\/\*.*@##@//' $WORKF > $WORKT
    elif [ $TRIAL -eq 20 ]; then sed -e 's/\*\//@##@/' -e 's/\/\*.*@##@//' $WORKF > $WORKT
    elif [ $TRIAL -eq 21 ]; then sed -e 's/ \. /\./g' -e 's/, /,/g' $WORKF > $WORKT
    elif [ $TRIAL -eq 22 ]; then sed -e 's/)[ \t]\+,/),/g' -e 's/)[ \t]\+;/);/g' $WORKF > $WORKT
    elif [ $TRIAL -eq 23 ]; then sed -e 's/\/\*\(.*\)\*\//\1/' $WORKF > $WORKT
    elif [ $TRIAL -eq 24 ]; then sed -e 's/field/f/g' $WORKF > $WORKT
    elif [ $TRIAL -eq 25 ]; then sed -e 's/field/f/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 26 ]; then sed -e 's/column/c/g' $WORKF > $WORKT
    elif [ $TRIAL -eq 27 ]; then sed -e 's/column/c/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 28 ]; then sed -e 's/col/c/g' $WORKF > $WORKT
    elif [ $TRIAL -eq 29 ]; then sed -e 's/col/c/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 30 ]; then sed -e 's/view/v/g' $WORKF > $WORKT
    elif [ $TRIAL -eq 31 ]; then sed -e 's/view\([0-9]\)*/v\1/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 32 ]; then sed -e 's/table/t/g' $WORKF > $WORKT
    elif [ $TRIAL -eq 33 ]; then sed -e 's/table\([0-9]\)*/t\1/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 34 ]; then sed -e 's/alias\([0-9]\)*/a\1/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 35 ]; then sed -e 's/ \([=<>!]\+\)/\1/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 36 ]; then sed -e 's/\([=<>!]\+\) /\1/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 37 ]; then sed -e 's/[=<>!]\+/=/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 38 ]; then sed -e 's/ .*[=<>!]\+.* / 1=1 /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 39 ]; then sed -e 's/([0-9]\+)/(1)/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 40 ]; then sed -e 's/([0-9]\+)//gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 41 ]; then sed -e 's/[ ]*/ /g' -e 's/^ //g' $WORKF > $WORKT
    elif [ $TRIAL -eq 42 ]; then sed -e 's/transforms\.//gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 43 ]; then NEXTACTION="& progress to the next stage"; sed -e 's/`//g' $WORKF > $WORKT
    else break
    fi
    SIZET=`stat -c %s $WORKT`
    if [ ${NOSKIP} -eq 0 -a $SIZEF -eq $SIZET ]; then 
      echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Skipping this trial as it does not reduce filesize"
    else
      if [ -f $WORKD/mysql.out ]; then echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Remaining size of input file: $SIZEF bytes ($LINECOUNTF lines)"; fi 
      run_and_check
      LINECOUNTF=`cat $WORKF | wc -l | tr -d '[\t\n ]*'`
      SIZEF=`stat -c %s $WORKF`
    fi
    TRIAL=$[$TRIAL+1]
  done
fi

#STAGE4: Execute various query syntax complexity reducing sed's to reduce testcase complexity further. Perform a check if the issue is still present for each replacement (set)
if [ $SKIPSTAGEBELOW -lt 4 -a $SKIPSTAGEABOVE -gt 4 ]; then
  STAGE=4
  TRIAL=1
  SIZEF=`stat -c %s $WORKF`
  echo_out "$ATLEASTONCE [Stage $STAGE] Now executing first trial in stage $STAGE"
  while :; do
    NEXTACTION="& try next query syntax complexity reducing sed"
    NOSKIP=0
  
    # The @##@ sed's remove comments like /*! NULL */. Each sed removes one /* */ block per line, so 3 sed's removes 3x /* */ for each line
    if   [ $TRIAL -eq 1  ]; then sed -e 's/IN[ \t]*(.*)/IN (SELECT 1)/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 2  ]; then sed -e 's/IN[ \t]*(.*)/IN (SELECT 1)/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 3  ]; then sed -e 's/ON[ \t]*(.*)/ON (1=1)/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 4  ]; then sed -e 's/ON[ \t]*(.*)/ON (1=1)/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 5  ]; then sed -e 's/FROM[ \t]*(.*)/FROM (SELECT 1)/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 6  ]; then sed -e 's/FROM[ \t]*(.*)/FROM (SELECT 1)/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 7  ]; then sed -e 's/WHERE.*ORDER BY/ORDER BY/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 8  ]; then sed -e 's/WHERE.*ORDER BY/ORDER BY/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 9  ]; then sed -e 's/WHERE.*LIMIT/LIMIT/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 10 ]; then sed -e 's/WHERE.*LIMIT/LIMIT/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 11 ]; then sed -e 's/WHERE.*GROUP BY/GROUP BY/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 12 ]; then sed -e 's/WHERE.*GROUP BY/GROUP BY/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 13 ]; then sed -e 's/WHERE.*HAVING/HAVING/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 14 ]; then sed -e 's/WHERE.*HAVING/HAVING/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 15 ]; then sed -e 's/ORDER BY.*WHERE/WHERE/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 16 ]; then sed -e 's/ORDER BY.*WHERE/WHERE/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 17 ]; then sed -e 's/ORDER BY.*LIMIT/LIMIT/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 18 ]; then sed -e 's/ORDER BY.*LIMIT/LIMIT/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 19 ]; then sed -e 's/ORDER BY.*GROUP BY/GROUP BY/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 20 ]; then sed -e 's/ORDER BY.*GROUP BY/GROUP BY/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 21 ]; then sed -e 's/ORDER BY.*HAVING/HAVING/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 22 ]; then sed -e 's/ORDER BY.*HAVING/HAVING/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 23 ]; then sed -e 's/LIMIT.*WHERE/WHERE/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 24 ]; then sed -e 's/LIMIT.*WHERE/WHERE/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 25 ]; then sed -e 's/LIMIT.*ORDER BY/ORDER BY/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 26 ]; then sed -e 's/LIMIT.*ORDER BY/ORDER BY/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 27 ]; then sed -e 's/LIMIT.*GROUP BY/GROUP BY/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 28 ]; then sed -e 's/LIMIT.*GROUP BY/GROUP BY/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 29 ]; then sed -e 's/LIMIT.*HAVING/HAVING/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 30 ]; then sed -e 's/LIMIT.*HAVING/HAVING/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 31 ]; then sed -e 's/GROUP BY.*WHERE/WHERE/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 32 ]; then sed -e 's/GROUP BY.*WHERE/WHERE/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 33 ]; then sed -e 's/GROUP BY.*ORDER BY/ORDER BY/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 34 ]; then sed -e 's/GROUP BY.*ORDER BY/ORDER BY/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 35 ]; then sed -e 's/GROUP BY.*LIMIT/LIMIT/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 36 ]; then sed -e 's/GROUP BY.*LIMIT/LIMIT/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 37 ]; then sed -e 's/GROUP BY.*HAVING/HAVING/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 38 ]; then sed -e 's/GROUP BY.*HAVING/HAVING/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 39 ]; then sed -e 's/HAVING.*WHERE/WHERE/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 40 ]; then sed -e 's/HAVING.*WHERE/WHERE/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 41 ]; then sed -e 's/HAVING.*ORDER BY/ORDER BY/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 42 ]; then sed -e 's/HAVING.*ORDER BY/ORDER BY/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 43 ]; then sed -e 's/HAVING.*LIMIT/LIMIT/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 44 ]; then sed -e 's/HAVING.*LIMIT/LIMIT/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 45 ]; then sed -e 's/HAVING.*GROUP BY/GROUP BY/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 46 ]; then sed -e 's/HAVING.*GROUP BY/GROUP BY/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 47 ]; then sed -e 's/LIMIT[[:digit:][:space:][:cntrl:]]*;$/;/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 48 ]; then sed -e 's/ORDER BY.*;$/;/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 49 ]; then sed -e 's/GROUP BY.*;$/;/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 50 ]; then sed -e 's/HAVING.*;$/;/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 51 ]; then sed -e 's/WHERE.*;$/;/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 52 ]; then sed -e 's/LIMIT.*;$/;/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 53 ]; then sed -e 's/GROUP BY.*;$/;/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 54 ]; then sed -e 's/ORDER BY.*;$/;/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 55 ]; then sed -e 's/HAVING.*;$/;/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 56 ]; then sed -e 's/WHERE.*;$/;/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 57 ]; then sed -e 's/(SELECT 1)/(1)/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 58 ]; then sed -e 's/ORDER BY \(.*\),\(.*\)/ORDER BY \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 59 ]; then sed -e 's/ORDER BY \(.*\),\(.*\)/ORDER BY \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 60 ]; then sed -e 's/ORDER BY \(.*\),\(.*\)/ORDER BY \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 61 ]; then sed -e 's/ORDER BY \(.*\),\(.*\)/ORDER BY \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 62 ]; then sed -e 's/ORDER BY \(.*\),\(.*\)/ORDER BY \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 63 ]; then sed -e 's/GROUP BY \(.*\),\(.*\)/GROUP BY \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 64 ]; then sed -e 's/GROUP BY \(.*\),\(.*\)/GROUP BY \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 65 ]; then sed -e 's/GROUP BY \(.*\),\(.*\)/GROUP BY \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 66 ]; then sed -e 's/GROUP BY \(.*\),\(.*\)/GROUP BY \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 67 ]; then sed -e 's/GROUP BY \(.*\),\(.*\)/GROUP BY \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 68 ]; then sed -e 's/SELECT \(.*\),\(.*\)/SELECT \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 69 ]; then sed -e 's/SELECT \(.*\),\(.*\)/SELECT \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 70 ]; then sed -e 's/SELECT \(.*\),\(.*\)/SELECT \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 71 ]; then sed -e 's/SELECT \(.*\),\(.*\)/SELECT \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 72 ]; then sed -e 's/SELECT \(.*\),\(.*\)/SELECT \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 73 ]; then sed -e 's/ SET \(.*\),\(.*\)/ SET \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 74 ]; then sed -e 's/ SET \(.*\),\(.*\)/ SET \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 75 ]; then sed -e 's/ SET \(.*\),\(.*\)/ SET \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 76 ]; then sed -e 's/ SET \(.*\),\(.*\)/ SET \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 77 ]; then sed -e 's/ SET \(.*\),\(.*\)/ SET \1/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 78 ]; then sed -e 's/AND.*IN/IN/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 79 ]; then sed -e 's/AND.*ON/ON/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 80 ]; then sed -e 's/AND.*WHERE/WHERE/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 81 ]; then sed -e 's/AND.*ORDER BY/ORDER BY/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 82 ]; then sed -e 's/AND.*GROUP BY/GROUP BY/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 83 ]; then sed -e 's/AND.*LIMIT/LIMIT/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 84 ]; then sed -e 's/AND.*HAVING/HAVING/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 85 ]; then sed -e 's/OR.*IN/IN/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 86 ]; then sed -e 's/OR.*ON/ON/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 87 ]; then sed -e 's/OR.*WHERE/WHERE/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 88 ]; then sed -e 's/OR.*ORDER BY/ORDER BY/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 89 ]; then sed -e 's/OR.*GROUP BY/GROUP BY/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 90 ]; then sed -e 's/OR.*LIMIT/LIMIT/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 91 ]; then sed -e 's/OR.*HAVING/HAVING/i' $WORKF > $WORKT
    elif [ $TRIAL -eq 92 ]; then sed -e 's/ NOT NULL/ /i' $WORKF > $WORKT
    elif [ $TRIAL -eq 93 ]; then sed -e 's/ NOT NULL/ /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 94 ]; then sed -e 's/ NULL/ /i' $WORKF > $WORKT
    elif [ $TRIAL -eq 95 ]; then sed -e 's/ NULL/ /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 96 ]; then sed -e 's/ AUTO_INCREMENT/ /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 97 ]; then sed -e 's/ ALGORITHM=MERGE/ /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 98 ]; then sed -e 's/ OR REPLACE/ /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 99 ]; then sed -e 's/ PRIMARY/ /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 100 ]; then sed -e 's/ PRIMARY KEY/ /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 101 ]; then sed -e 's/ DEFAULT NULL/ /i' $WORKF > $WORKT
    elif [ $TRIAL -eq 102 ]; then sed -e 's/ DEFAULT NULL/ /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 103 ]; then sed -e 's/ DEFAULT 0/ /i' $WORKF > $WORKT
    elif [ $TRIAL -eq 104 ]; then sed -e 's/ DEFAULT 0/ /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 105 ]; then sed -e "s/ DEFAULT '2038-01-19 03:14:07'/ /i" $WORKF > $WORKT
    elif [ $TRIAL -eq 106 ]; then sed -e "s/ DEFAULT '2038-01-19 03:14:07'/ /gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 107 ]; then sed -e "s/ DEFAULT '1970-01-01 00:00:01'/ /i" $WORKF > $WORKT
    elif [ $TRIAL -eq 108 ]; then sed -e "s/ DEFAULT '1970-01-01 00:00:01'/ /gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 109 ]; then sed -e 's/ DEFAULT CURRENT_TIMESTAMP/ /i' $WORKF > $WORKT
    elif [ $TRIAL -eq 110 ]; then sed -e 's/ DEFAULT CURRENT_TIMESTAMP/ /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 111 ]; then sed -e 's/ ON UPDATE CURRENT_TIMESTAMP/ /i' $WORKF > $WORKT
    elif [ $TRIAL -eq 112 ]; then sed -e 's/ ON UPDATE CURRENT_TIMESTAMP/ /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 113 ]; then sed -e 's/ IF NOT EXISTS / /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 114 ]; then sed -e 's/ DISTINCT / /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 115 ]; then sed -e 's/ SQL_.*_RESULT / /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 116 ]; then sed -e 's/CHARACTER SET[ ]*.*[ ]*COLLATE[ ]*.*\([, ]\)/\1/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 117 ]; then sed -e 's/CHARACTER SET[ ]*.*\([, ]\)/\1/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 118 ]; then sed -e 's/COLLATE[ ]*.*\([, ]\)/\1/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 119 ]; then sed -e 's/ LEFT / /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 120 ]; then sed -e 's/ RIGHT / /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 121 ]; then sed -e 's/ OUTER / /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 122 ]; then sed -e 's/ INNER / /gi' -e 's/ CROSS / /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 123 ]; then sed -e 's/[a-z0-9]\+_//' $WORKF > $WORKT
    elif [ $TRIAL -eq 124 ]; then sed -e 's/[a-z0-9]\+_//' $WORKF > $WORKT
    elif [ $TRIAL -eq 125 ]; then sed -e 's/[a-z0-9]\+_//' $WORKF > $WORKT
    elif [ $TRIAL -eq 126 ]; then sed -e 's/[a-z0-9]\+_//' $WORKF > $WORKT
    elif [ $TRIAL -eq 127 ]; then sed -e 's/[a-z0-9]\+_//' $WORKF > $WORKT
    elif [ $TRIAL -eq 128 ]; then sed -e 's/[a-z0-9]\+_//' $WORKF > $WORKT
    elif [ $TRIAL -eq 129 ]; then sed -e 's/alias/a/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 130 ]; then sed -e 's/SELECT .* /SELECT * /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 131 ]; then sed -e 's/SELECT .* /SELECT * /i' $WORKF > $WORKT
    elif [ $TRIAL -eq 132 ]; then sed -e 's/SELECT .* /SELECT 1 /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 133 ]; then sed -e 's/SELECT .* /SELECT 1 /i' $WORKF > $WORKT
    elif [ $TRIAL -eq 134 ]; then sed -e 's/[\t ]\+/ /g' -e 's/ *\([;,]\)/\1/g' -e 's/ $//g' -e 's/^ //g' $WORKF > $WORKT
    elif [ $TRIAL -eq 135 ]; then sed -e 's/CHARACTER[ ]*SET[ ]*latin1/ /i' $WORKF > $WORKT
    elif [ $TRIAL -eq 136 ]; then sed -e 's/CHARACTER[ ]*SET[ ]*utf8/ /i' $WORKF > $WORKT
    elif [ $TRIAL -eq 137 ]; then sed -e 's/SELECT .* /SELECT 1 /gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 138 ]; then sed -e 's/COLUMN_FORMAT COMPRESSED/ /i' $WORKF > $WORKT
    elif [ $TRIAL -eq 139 ]; then sed -e 's/INTEGER/INT/gi' $WORKF > $WORKT
    elif [ $TRIAL -eq 140 ]; then NEXTACTION="& progress to the next stage"; sed -e 's/DROP DATABASE transforms;CREATE DATABASE transforms;//' $WORKF > $WORKT
    else break
    fi
    SIZET=`stat -c %s $WORKT`
    if [ ${NOSKIP} -eq 0 -a $SIZEF -eq $SIZET ]; then 
      echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Skipping this trial as it does not reduce filesize"
    else
      if [ -f $WORKD/mysql.out ]; then echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Remaining size of input file: $SIZEF bytes ($LINECOUNTF lines)"; fi 
      run_and_check
      LINECOUNTF=`cat $WORKF | wc -l | tr -d '[\t\n ]*'`
      SIZEF=`stat -c %s $WORKF`
    fi
    TRIAL=$[$TRIAL+1]
  done
fi

#STAGE5: Rename tables and views to generic tx/vx names. This stage is not size bound (i.e. testcase size is not checked pre-run to see if the run can be skipped like in some other stages). Perform a check if the issue is still present for each replacement (set). 
if [ $SKIPSTAGEBELOW -lt 5 -a $SKIPSTAGEABOVE -gt 5 ]; then
  STAGE=5
  TRIAL=1
  echo_out "$ATLEASTONCE [Stage $STAGE] Now executing first trial in stage $STAGE"
  NEXTACTION="& try next testcase complexity reducing sed"

  # Change tablenames to tx
  COUNTTABLES=$(grep -E "CREATE[\t ]*TABLE" $WORKF | wc -l)
  if [ $COUNTTABLES -gt 0 ]; then
    for i in $(eval echo {$COUNTTABLES..1}); do  # Reverse order
      # the '...\n/2' sed is a precaution against multiple CREATE TABLEs on one line (it replaces the second occurence)
      TABLENAME=$(grep -E -m$i "CREATE[\t ]*TABLE" $WORKF | tail -n1 | sed -e 's/CREATE[\t ]*TABLE/\n/2' \
        | head -n1 | sed -e 's/CREATE[\t ]*TABLE[\t ]*\(.*\)[\t ]*(/\1/' -e 's/ .*//1' -e 's/(.*//1')
      sed -e "s/\([(. ]\)$TABLENAME\([ )]\)/\1 $TABLENAME \2/gi;s/ $TABLENAME / t$i /gi" $WORKF > $WORKT
      if [ "$TABLENAME" = "t$i" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Skipping this trial as table $i is already named 't$i' in the file"
      else 
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Trying to rename table '$TABLENAME' to 't$i'"
        run_and_check
      fi
      TRIAL=$[$TRIAL+1]
    done
  fi

  # Change viewnames to vx
  COUNTVIEWS=$(grep -E "CREATE[\t ]*VIEW" $WORKF | wc -l)
  if [ $COUNTVIEWS -gt 0 ]; then
    for i in $(eval echo {$COUNTVIEWS..1}); do  # Reverse order
      # the '...\n/2' sed is a precaution against multiple CREATE VIEWs on one line (it replaces the second occurence)
      VIEWNAME=$(grep -E -m$i "CREATE[\t ]*VIEW" $WORKF | tail -n1 | sed -e 's/CREATE[\t ]*VIEW/\n/2' \
        | head -n1 | sed -e 's/CREATE[\t ]*VIEW[\t ]*\(.*\)[\t ]*(/\1/' -e 's/ .*//1' -e 's/(.*//1')
      sed -e "s/\([(. ]\)$VIEWNAME\([ )]\)/\1 $VIEWNAME \2/gi;s/ $VIEWNAME / v$i /gi" $WORKF > $WORKT
      if [ "$VIEWNAME" = "v$i" ]; then
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Skipping this trial as view $i is already named 'v$i' in the file"
      else 
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Trying to rename view '$VIEWNAME' to 'v$i'"
        run_and_check
      fi
      TRIAL=$[$TRIAL+1]
    done
  fi
fi

#STAGE6: Eliminate columns to reduce testcase complexity further. Perform a check if the issue is still present for each replacement (set).
if [ $SKIPSTAGEBELOW -lt 6 -a $SKIPSTAGEABOVE -gt 6 ]; then
  STAGE=6
  TRIAL=1
  SIZEF=`stat -c %s $WORKF`
  echo_out "$ATLEASTONCE [Stage $STAGE] Now executing first trial in stage $STAGE"
  NEXTACTION="& try and rename this column (if it failed removal) or remove the next column"

  # CREATE TABLE name (...); statements on one line are split to obtain one column per line by the initial verification (STAGE V).
  # And, another situation, CREATE TABLE statements with each column on a new line is the usual RQG output. Both these cases are handled.
  # However, this stage assumes that each column is on a new line. As such, the only unhandled situation is where there is a mix of new lines in 
  # the CREATE TABLE statement, which is to be avoided (and is rather unlikely). In such cases, cleanup the testcase manually to have this format:
  # CREATE TABLE name (
  # <col defs, one per line>,    #Note the trailing comma
  # <col defs, one per line>,
  # <key def, one or more per line>
  # ) ENGINE=abc;

  COUNTTABLES=$(grep -E "CREATE[\t ]*TABLE" $WORKF | wc -l)
  for t in $(eval echo {$COUNTTABLES..1}); do  # Reverse order process all tables
    # the '...\n/2' sed is a precaution against multiple CREATE TABLEs on one line (it replaces the second occurence)
    TABLENAME=$(grep -E -m$t "CREATE[\t ]*TABLE" $WORKF | tail -n1 | sed -e 's/CREATE[\t ]*TABLE/\n/2' \
      | head -n1 | sed -e 's/CREATE[\t ]*TABLE[\t ]*\(.*\)[\t ]*(/\1/' -e 's/ .*//1' -e 's/(.*//1')

    # Check if this table ($TABLENAME) is references in aother INSERT..INTO..$TABLENAME2..SELECT..$TABLENAME line.
    # If so, reducer does not need to process this table since it will be processed later when reducer gets to the table $TABLENAME2
    # This is basically an optimization to avoid x (number of colums) unnecessary restarts which will definitely fail:
    # Example: CREATE TABLE t1 (id INT); INSERT INTO t1 VALUES (1); CREATE TABLE t2 (id2 INT): INSERT INTO t2 SELECT * FROM t1;
    # One cannot remove t1.id because t2 has the same number of columsn and does a select from t1
    if grep -E --binary-files=text -qi "INSERT.*INTO.*SELECT.*FROM.*$TABLENAME" $WORKF; then
      echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Skipping column reduction for table '$TABLENAME' as it is present in a INSERT..SELECT..$TABLENAME. This will be/has been reduced elsewhere"
      echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Will now try and simplify the column names of this table ('$TABLENAME') to more uniform names"
      COLUMN=1
      COLS=$(cat $WORKF | awk "/CREATE.*TABLE.*$TABLENAME/,/;/" | sed 's/^ \+//' | grep -E --binary-files=text -vi "CREATE|ENGINE|^KEY|^PRIMARY|;" | sed 's/ .*$//' | grep -E --binary-files=text -v "\(|\)")
      COUNTCOLS=$(printf "%b\n" "$COLS" | wc -l)
      for COL in $COLS; do
        if [ "$COL" != "c$C_COL_COUNTER" ]; then
          # Try and rename column now to cx to make testcase cleaner
          if [ -f $WORKD/mysql.out ]; then echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Column $COLUMN/$COUNTCOLS] Now attempting to rename column '$COL' to a more uniform 'c$C_COL_COUNTER'"; fi
          sed -e "s/$COL/c$C_COL_COUNTER/g" $WORKF > $WORKT
          C_COL_COUNTER=$[$C_COL_COUNTER+1]
          run_and_check
          if [ $? -eq 1 ]; then 
            # This column was removed, reducing column count
            COUNTCOLS=$[$COUNTCOLS-1]
          fi
          COLUMN=$[$COLUMN+1]
          LINECOUNTF=`cat $WORKF | wc -l | tr -d '[\t\n ]*'`
          SIZEF=`stat -c %s $WORKF`
        else
          if [ -f $WORKD/mysql.out ]; then echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Column $COLUMN/$COUNTCOLS] Not renaming column '$COL' as it's name is already optimal"; fi
        fi
      done
    else 
      NUMOFINVOLVEDTABLES=1

      # Check if there are INSERT..INTO..$TABLENAME..SELECT..$TABLENAME2 lines. If so, fetch $TABLENAME2 etc.
      TEMPTABLENAME=$TABLENAME
      while grep -E --binary-files=text -qi "INSERT.*INTO.*$TEMPTABLENAME.*SELECT" $WORKF; do
        NUMOFINVOLVEDTABLES=$[$NUMOFINVOLVEDTABLES+1]
        # the '...\n/2' sed is a precaution against multiple INSERT INTOs on one line (it replaces the second occurence)
        export TABLENAME$NUMOFINVOLVEDTABLES=$(grep -E "INSERT.*INTO.*$TEMPTABLENAME.*SELECT" $WORKF | tail -n1 | sed -e 's/INSERT.*INTO/\n/2' \
          | head -n1 | sed -e "s/INSERT.*INTO.*$TEMPTABLENAME.*SELECT.*FROM[\t ]*\(.*\)/\1/" -e 's/ //g;s/;//g')
        TEMPTABLENAME=$(eval echo $(echo '$TABLENAME'"$NUMOFINVOLVEDTABLES"))
      done

      COLUMN=1
      COLS=$(cat $WORKF | awk "/CREATE.*TABLE.*$TABLENAME/,/;/" | sed 's/^ \+//' | grep -E --binary-files=text -vi "CREATE|ENGINE|^KEY|^PRIMARY|;" | sed 's/ .*$//' | grep -E --binary-files=text -v "\(|\)")
      COUNTCOLS=$(printf "%b\n" "$COLS" | wc -l) 
      # The inner loop below is called for each table (= each trial) and processes all columns for the table in question
      # So the hierarchy is: reducer > STAGE6 > TRIAL x (various tables) > Column y of table x
      for COL in $COLS; do
        echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Column $COLUMN/$COUNTCOLS] Trying to eliminate column '$COL' in table '$TABLENAME'"

        # Eliminate the column from the correct CREATE TABLE table (this will match the first occurence of that column name in the correct CREATE TABLE)
        # This sed presumes that each column is on one line, by itself, terminated by a comma (can be improved upon as per the above remark note)
        WORKT2=`echo $WORKT | sed 's/$/.2/'`
        sed -e "/CREATE.*TABLE.*$TABLENAME/,/^[ ]*$COL.*,/s/^[ ]*$COL.*,//1" $WORKF | grep -E --binary-files=text -v "^$" > $WORKT2  # Remove the column from table defintion
        # Write the testcase with removed column table definition to WORKT as well in case there are no INSERT removals
        # (and hence $WORKT will not be replaced with $WORKT2 anymore below, so reducer does it here as a harmless, but potentially needed, precaution)
        cp -f $WORKT2 $WORKT  

        # If present, the script also need to drop the same column from the INSERT for that table, otherwise the testcase will definitely fail (incorrect INSERT)
        # Small limitation 1: ,',', (a comma inside a txt string) is not handled correctly. Column elimination will work, but only upto this occurence (per table)
        # Small limitation 2: INSERT..INTO..SELECT <specific columns> does not work. SELECT * in such cases is handled. You could manually edit the testcase.

        for c in $(eval echo {1..$NUMOFINVOLVEDTABLES}); do
          if   [ $c -eq 1 ]; then 
            # We are now processing any INSERT..INTO..$TABLENAME..VALUES reductions
            # Noth much is required here. In effect, this is what happens here:
            # CREATE TABLE t1 (id INT); 
            # INSERT INTO t1 VALUES (1);
            # reducer will try and eliminate "(1)" (after "id" was removed from the table defintion above already)
            # Note that this will also run (due to the for loop) for a NUMOFINVOLVEDTABLES=2+ run - i.e. if an INSERT..INTO..$TABLENAME..SELECT is detected,
            # This run ensures that (see t1/t2 example below) that any additional INSERT INTO t2 VALUES (2) (besides the INSERT SELECT) are covered
            TABLENAME_OLD=$TABLENAME
          elif [ $c -ge 2 ]; then
            # We are now processing any eliminations from other tables to ensure that INSERT..INTO..$TABLENAME..SELECT works for this table
            # We do this by setting TABLENAME to $TABLENAME2 etc. In effect, this is what happens:
            # CREATE TABLE t1 (id INT); 
            # INSERT INTO t1 VALUES (1);
            # CREATE TABLE t2 (id2 INT):
            # INSERT INTO t2 SELECT * FROM t1;
            # reducer will try and eliminate "(1)" from table t1 (after "id2" was removed from the table defintion above already)
            # An extra part (see * few lines lower) will ensure that "id" is also removed from t1
            TABLENAME=$(eval echo $(echo '$TABLENAME'"$c"))   # Replace TABLENAME with TABLENAMEx thereby eliminating all "chained" columns
            echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Column $COLUMN/$COUNTCOLS] INSERT..SELECT into this table from another one detected: removing corresponding column $COLUMN in table '$TABLENAME'"
            WORKT3=`echo $WORKT | sed 's/$/.3/'`
            COL_LINE=$[$(cat $WORKT2 | grep -E -m1 -n "CREATE.*TABLE.*$TABLENAME" | awk -F":" '{print $1}') + $COLUMN]
            cat $WORKT2 | sed -e "${COL_LINE}d" > $WORKT3  # (*) Remove the column from the connected table defintion
            cp -f $WORKT3 $WORKT2
            rm $WORKT3
          else 
            echo "ASSERT: NUMOFINVOLVEDTABLES!=1||2: $NUMOFINVOLVEDTABLES!=1||2"; 
            echo "Terminating now."
            exit 1
          fi

          # First count how many actual INSERT rows there are
          COUNTINSERTS=0
          COUNTINSERTS=$(for INSERT in $(cat $WORKT2 | awk "/INSERT.*INTO.*$TABLENAME.*VALUES/,/;/" | \
            sed "s/;/,/;s/^[ ]*(/(\n/;s/)[ ,;]$/\n)/;s/)[ ]*,[ ]*(/\n/g" | \
            grep -E --binary-files=text -v "^[ ]*[\(\)][ ]*$|INSERT"); do \
            echo $INSERT; \
            done | wc -l)

          if [ $COUNTINSERTS -gt 0 ]; then
            # Loop through each line within a single INSERT (ex: INSERT INTO t1 VALUES ('a',1),('b',2);), and through multiple INSERTs (ex: INSERT .. INSERT ..)
            # And each time grab the "between ( and )" information and therein remove the n-th column ($COLUMN) value reducer is trying to remove. Then use a
            # simple sed to replace the old "between ( and )" with the new "between ( and )" which contains one less column (the correct one which removed from
            # the CREATE TABLE statement above also. Then re-test if the issue remains and swap files if this is the case, as usual.
            if [ $c -ge 2 ]; then 
              echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Column $COLUMN/$COUNTCOLS] Also removing $COUNTINSERTS INSERT..VALUES for column $COLUMN in table '$TABLENAME' to match column removal in said table"
            else
              echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Column $COLUMN/$COUNTCOLS] Removing $COUNTINSERTS INSERT..VALUES for column '$COL' in table '$TABLENAME'"
            fi
            for i in $(eval echo {1..$COUNTINSERTS}); do
              FROM=$(for INSERT in $(cat $WORKT2 | awk "/INSERT.*INTO.*$TABLENAME.*VALUES/,/;/" | \
                sed "s/;/,/;s/^[ ]*(/(\n/;s/)[ ,;]$/\n)/;s/)[ ]*,[ ]*(/\n/g" | \
                grep -E --binary-files=text -v "^[ ]*[\(\)][ ]*$|INSERT"); do \
                echo $INSERT; \
                done | awk "{if(NR==$i) print "'$1}')

              TO_DONE=0
              TO=$(for INSERT in $(cat $WORKT2 | awk "/INSERT.*INTO.*$TABLENAME.*VALUES/,/;/" | \
                sed "s/;/,/;s/^[ ]*(/(\n/;s/)[ ,;]$/\n)/;s/)[ ]*,[ ]*(/\n/g" | \
                grep -E --binary-files=text -v "^[ ]*[\(\)][ ]*$|INSERT"); do \
                echo $INSERT | tr ',' '\n' | awk "{if(NR!=$COLUMN && $TO_DONE==0) print "'$1}'; echo "==>=="; \
                done | tr '\n' ',' | sed 's/,==>==/\n/g' | sed 's/^,//' | awk "{if(NR==$i) print "'$1}')
              TO_DONE=1

              # Fix backslash issues (replace \ with \\) like 'you\'ve' - i.e. a single quote within single quoted INSERT values
              # This insures the regex matches in the sed below against the original file: you\'ve > you\\'ve (here) > you\'ve (in the sed)
              FROM=$(echo $FROM | sed 's|\\|\\\\|g')
              TO=$(echo $TO | sed 's|\\|\\\\|g')

              # The actual replacement
              cat $WORKT2 | sed "s/$FROM/$TO/" > $WORKT
              cp -f $WORKT $WORKT2

              #DEBUG
              #echo_out "i: |$i|";echo_out "from: |$FROM|";echo_out "_to_: |$TO|";
            done
          fi
          # DEBUG
          #echo_out "c: |$c|";echo_out "COUNTINSERTS: |$COUNTINSERTS|";echo_out "COLUMN: |$COLUMN|";echo_out "diff: $(diff $WORKF $WORKT2)"
          #read -p "pause"

        done
        rm $WORKT2
        TABLENAME=$TABLENAME_OLD
    
        if [ -f $WORKD/mysql.out ]; then echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Column $COLUMN/$COUNTCOLS] Remaining size of input file: $SIZEF bytes ($LINECOUNTF lines)"; fi 
        run_and_check
        if [ $? -eq 0 ]; then 
          if [ "$COL" != "c$C_COL_COUNTER" ]; then
            LINECOUNTF=`cat $WORKF | wc -l | tr -d '[\t\n ]*'`
            SIZEF=`stat -c %s $WORKF`

            # This column was not removed. Try and rename column now to cx to make testcase cleaner
            if [ -f $WORKD/mysql.out ]; then echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Column $COLUMN/$COUNTCOLS] Now attempting to rename this column ('$COL') to a more uniform 'c$C_COL_COUNTER'"; fi
            sed -e "s/$COL/c$C_COL_COUNTER/g" $WORKF > $WORKT
            C_COL_COUNTER=$[$C_COL_COUNTER+1]
            run_and_check
          else
            if [ -f $WORKD/mysql.out ]; then echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] [Column $COLUMN/$COUNTCOLS] Not renaming column '$COL' as it's name is already optimal"; fi
          fi
          
          # Only advance the column number if there was no issue showing, otherwise stay on the same column (If the issue does show, 
          # the script will remove the current column and shift all other columns down by one, hence it has to stay in the same 
          # place as this will contain the next column)
          COLUMN=$[$COLUMN+1]
        else
          # This column was removed, reducing column count
          COUNTCOLS=$[$COUNTCOLS-1]
        fi
        LINECOUNTF=`cat $WORKF | wc -l | tr -d '[\t\n ]*'`
        SIZEF=`stat -c %s $WORKF`
      done
    fi
    TRIAL=$[$TRIAL+1]
  done
fi

#STAGE7: Execute various final testcase cleanup sed's. Perform a check if the issue is still present for each replacement (set)
if [ $SKIPSTAGEBELOW -lt 7 -a $SKIPSTAGEABOVE -gt 7 ]; then
  STAGE=7
  TRIAL=1
  SIZEF=`stat -c %s $WORKF`
  echo_out "$ATLEASTONCE [Stage $STAGE] Now executing first trial in stage $STAGE"
  while :; do
    NEXTACTION="& try next testcase complexity reducing sed"
    NOSKIP=0
    
    if   [ $TRIAL -eq 1   ]; then sed -e "s/[\t]\+/ /g" $WORKF > $WORKT
    elif [ $TRIAL -eq 2   ]; then sed -e "s/[ ]\+/ /g" $WORKF > $WORKT
    elif [ $TRIAL -eq 3   ]; then sed -e "s/[ ]*,/,/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 4   ]; then sed -e "s/,[ ]*/,/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 5   ]; then sed -e "s/[ ]*;[ ]*/;/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 6   ]; then sed -e "s/^[ ]*//g" -e "s/[ ]*$//g" $WORKF > $WORKT
    elif [ $TRIAL -eq 7   ]; then sed -e "s/GRANDPARENT/gp/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 8   ]; then sed -e "s/PARENT/p/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 9   ]; then sed -e "s/CHILD/c/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 10  ]; then sed -e "s/\([(,]\)[ ]*'a'[ ]*/\1''/g;s/[ ]*'a'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT  # Simplify INSERT VALUES
    elif [ $TRIAL -eq 11  ]; then sed -e "s/\([(,]\)[ ]*''[ ]*/\1/g;s/[ ]*''[ ]*\([,)]\)/\1/g" $WORKF > $WORKT  # Try and elimiante ''
    elif [ $TRIAL -eq 12  ]; then sed -e "s/\([(,]\)[ ]*'[a-z]'[ ]*/\1''/g;s/[ ]*'[a-z]'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 13  ]; then sed -e "s/\([(,]\)[ ]*'[A-Z]'[ ]*/\1''/g;s/[ ]*'[A-Z]'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 14  ]; then sed -e "s/\([(,]\)[ ]*'[a-zA-Z]'[ ]*/\1''/g;s/[ ]*'[a-zA-Z]'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 15  ]; then sed -e "s/\([(,]\)[ ]*'[a-z]*'[ ]*/\1''/g;s/[ ]*'[a-z]*'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 16  ]; then sed -e "s/\([(,]\)[ ]*'[A-Z]*'[ ]*/\1''/g;s/[ ]*'[A-Z]*'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 17  ]; then sed -e "s/\([(,]\)[ ]*'[a-zA-Z]*'[ ]*/\1''/g;s/[ ]*'[a-zA-Z]*'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 18  ]; then sed -e "s/\([(,]\)[ ]*''[ ]*/\1/g;s/[ ]*''[ ]*\([,)]\)/\1/g" $WORKF > $WORKT  # Try and elimiante '' again now
    elif [ $TRIAL -eq 19  ]; then sed -e "s/([ ]*[0-9][ ]*,/(0,/g;s/,[ ]*[0-9][ ]*,/,0,/g;s/,[ ]*[0-9][ ]*)/,0)/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 20  ]; then sed -e "s/([ ]*[0-9]*[ ]*,/(0,/g;s/,[ ]*[0-9]*[ ]*,/,0,/g;s/,[ ]*[0-9]*[ ]*)/,0)/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 21  ]; then sed -e "s/([ ]*NULL[ ]*,/(1,/g;s/,[ ]*NULL[ ]*,/,1,/g;s/,[ ]*NULL[ ]*)/,1)/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 22  ]; then sed -e "s/([ ]*NULL[ ]*,/(0,/g;s/,[ ]*NULL[ ]*,/,0,/g;s/,[ ]*NULL[ ]*)/,0)/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 23  ]; then sed -e "s/([ ]*NULL[ ]*,/('',/g;s/,[ ]*NULL[ ]*,/,'',/g;s/,[ ]*NULL[ ]*)/,'')/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 24  ]; then sed -e "s/\([(,]\)[ ]*''[ ]*/\1/g;s/[ ]*''[ ]*\([,)]\)/\1/g" $WORKF > $WORKT  # Try and elimiante '' again now
    elif [ $TRIAL -eq 25  ]; then sed -e "s/\([(,]\)[ ]*'[0-9]'[ ]*/\1''/g;s/[ ]*'[0-9]'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 26  ]; then sed -e "s/\([(,]\)[ ]*'[0-9]*'[ ]*/\1''/g;s/[ ]*'[0-9]*'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 27  ]; then sed -e "s/\([(,]\)[ ]*'[-0-9]*'[ ]*/\1''/g;s/[ ]*'[-0-9]*'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT  # Date
    elif [ $TRIAL -eq 28  ]; then sed -e "s/\([(,]\)[ ]*'[:0-9]*'[ ]*/\1''/g;s/[ ]*'[:0-9]*'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT  # Time
    elif [ $TRIAL -eq 29  ]; then sed -e "s/\([(,]\)[ ]*'[:.0-9]*'[ ]*/\1''/g;s/[ ]*'[:.0-9]*'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT  # Time, FSP
    elif [ $TRIAL -eq 30  ]; then sed -e "s/\([(,]\)[ ]*'[-: 0-9]*'[ ]*/\1''/g;s/[ ]*'[-: 0-9]*'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT  # Datetime
    elif [ $TRIAL -eq 31  ]; then sed -e "s/\([(,]\)[ ]*'[-.: 0-9]*'[ ]*/\1''/g;s/[ ]*'[-.: 0-9]*'[ ]*\([,)]\)/''\1/g" $WORKF > $WORKT  # Dt, FSP
    elif [ $TRIAL -eq 32  ]; then sed -e "s/\([(,]\)[ ]*''[ ]*/\1/g;s/[ ]*''[ ]*\([,)]\)/\1/g" $WORKF > $WORKT  # Try and elimiante '' again now
    elif [ $TRIAL -eq 33  ]; then sed -e "s/[ ]*'[a-z]'[ ]*/''/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 34  ]; then sed -e "s/[ ]*'[A-Z]'[ ]*/''/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 35  ]; then sed -e "s/[ ]*'[a-zA-Z]'[ ]*/''/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 36  ]; then sed -e "s/[ ]*'[a-z]*'[ ]*/''/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 37  ]; then sed -e "s/[ ]*'[A-Z]*'[ ]*/''/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 38  ]; then sed -e "s/[ ]*'[a-zA-Z]*'[ ]*/''/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 39  ]; then sed -e "s/[ ]*[0-9][ ]*/0/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 40  ]; then sed -e "s/[ ]*[0-9]*[ ]*/0/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 41  ]; then sed -e "s/[ ]*NULL[ ]*//g" $WORKF > $WORKT
    elif [ $TRIAL -eq 42  ]; then sed -e "s/[ ]*NULL[ ]*/0/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 43  ]; then sed -e "s/[ ]*NULL[ ]*/''/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 44  ]; then sed -e "s/[ ]*'[0-9]'[ ]*/''/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 45  ]; then sed -e "s/[ ]*'[0-9]*'[ ]*/''/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 46  ]; then sed -e "s/[0-9]/0/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 47  ]; then sed -e "s/[0-9]\+/0/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 48  ]; then sed -e "s/[ ]*AUTO_INCREMENT=[0-9]*//gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 49  ]; then sed -e "s/[ ]*AUTO_INCREMENT[ ]*,/,/gi" $WORKF > $WORKT 
    elif [ $TRIAL -eq 50  ]; then sed -e "s/PRIMARY[ ]*KEY.*,//g" $WORKF > $WORKT
         # TODO: add situation where PRIMARY KEY is last column (i.e. remove comma on preceding line)
    elif [ $TRIAL -eq 51  ]; then sed -e "s/PRIMARY[ ]*KEY[ ]*(\(.*\))/KEY (\1)/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 52  ]; then sed -e "s/KEY[ ]*(\(.*\),.*)/KEY(\1)/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 53  ]; then sed -e "s/ ENGINE=MEMORY/ENGINE=InnoDB/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 54  ]; then sed -e "s/ ENGINE=MyISAM/ENGINE=InnoDB/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 55  ]; then sed -e "s/,LOAD_FILE('[A-Za-z0-9\/.]*'),/,'',/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 56  ]; then sed -e "s/_tinyint/ti/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 57  ]; then sed -e "s/_smallint/si/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 58  ]; then sed -e "s/_mediumint/mi/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 59  ]; then sed -e "s/_bigint/bi/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 60  ]; then sed -e "s/_int/i/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 61  ]; then sed -e "s/_decimal/dc/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 62  ]; then sed -e "s/_float/f/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 63  ]; then sed -e "s/_bit/bi/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 64  ]; then sed -e "s/_double/do/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 65  ]; then sed -e "s/_nokey/nk/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 66  ]; then sed -e "s/_key/k/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 67  ]; then sed -e "s/_varchar/vc/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 68  ]; then sed -e "s/_char/c/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 69  ]; then sed -e "s/_datetime/dt/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 70  ]; then sed -e "s/_date/d/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 71  ]; then sed -e "s/_time/t/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 72  ]; then sed -e "s/_timestamp/ts/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 73  ]; then sed -e "s/_year/y/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 74  ]; then sed -e "s/_blob/b/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 75  ]; then sed -e "s/_tinyblob/tb/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 76  ]; then sed -e "s/_mediumblob/mb/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 77  ]; then sed -e "s/_longblob/lb/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 78  ]; then sed -e "s/_text/te/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 79  ]; then sed -e "s/_tinytext/tt/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 80  ]; then sed -e "s/_mediumtext/mt/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 81  ]; then sed -e "s/_longtext/lt/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 82  ]; then sed -e "s/_binary/bn/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 83  ]; then sed -e "s/_varbinary/vb/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 84  ]; then sed -e "s/_enum/e/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 85  ]; then sed -e "s/_set/s/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 86  ]; then sed -e "s/_not/n/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 87  ]; then sed -e "s/_null/nu/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 88  ]; then sed -e "s/_latin1/l/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 89  ]; then sed -e "s/_utf8/u/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 90  ]; then sed -e "s/;[ ]*;/;/g" -e "s/[ ]*,[ ]*/,/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 91  ]; then sed -e "s/VARCHAR[ ]*(\(.*\))/CHAR (\1)/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 92  ]; then sed -e "s/VARBINARY[ ]*(\(.*\))/BINARY (\1)/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 93  ]; then sed -e "s/DATETIME/DATE/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 94  ]; then sed -e "s/TIME/DATE/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 95  ]; then sed -e "s/TINYBLOB/BLOB/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 96  ]; then sed -e "s/MEDIUMBLOB/BLOB/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 97  ]; then sed -e "s/LONGBLOB/BLOB/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 98  ]; then sed -e "s/TINYTEXT/TEXT/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 99  ]; then sed -e "s/MEDIUMTEXT/TEXT/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 100 ]; then sed -e "s/LONGTEXT/TEXT/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 101 ]; then sed -e "s/INTEGER/INT/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 102 ]; then sed -e "s/TINYINT/INT/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 103 ]; then sed -e "s/SMALLINT/INT/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 104 ]; then sed -e "s/MEDIUMINT/INT/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 105 ]; then sed -e "s/BIGINT/INT/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 106 ]; then sed -e "s/WHERE[ ]*(\(.*\),.*)/WHERE (\1)/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 107 ]; then sed -e "s/\\\'[0-9a-zA-Z]\\\'/0/g" $WORKF > $WORKT  # \'c\' in PS matching
    elif [ $TRIAL -eq 108 ]; then sed -e "s/\\\'[0-9a-zA-Z]\\\'/1/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 109 ]; then sed -e "s/\\\'[0-9a-zA-Z]*\\\'/0/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 110 ]; then sed -e "s/\\\'[0-9a-zA-Z]*\\\'/1/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 111 ]; then sed -e "s/\\\'[0-9a-zA-Z]*\\\'/\\\'\\\'/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 112 ]; then sed -e "s/<>/=/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 113 ]; then sed -e "s/([ ]*(/((/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 114 ]; then sed -e "s/)[ ]*)/))/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 115 ]; then sed -e "s/([ ]*/(/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 116 ]; then sed -e "s/[ ]*)/)/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 117 ]; then sed -e "s/ prep_stmt_[0-9]*/ p1/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 118 ]; then sed -e '/INSERT[ ]*INTO/,/)/{s/INSERT[ ]*INTO[ ]*\(.*\)[ ]*(/INSERT INTO \1/p;d}' $WORKF > $WORKT
    elif [ $TRIAL -eq 119 ]; then sed -e "s/QUICK //gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 120 ]; then sed -e "s/LOW_PRIORITY //gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 121 ]; then sed -e "s/IGNORE //gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 122 ]; then sed -e "s/enum[ ]*('[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*',/ENUM('','','','','',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 123 ]; then sed -e "s/enum[ ]*('[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*',/ENUM('','','','','',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 124 ]; then sed -e "s/enum[ ]*('[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*',/ENUM('','','','','',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 125 ]; then sed -e "s/enum[ ]*('[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*',/ENUM('','','','','',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 126 ]; then sed -e "s/enum[ ]*('','','','','','',/ENUM('',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 127 ]; then sed -e "s/enum[ ]*('','','','',/ENUM('',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 128 ]; then sed -e "s/enum[ ]*('','','',/ENUM('',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 129 ]; then sed -e "s/enum[ ]*('','',/ENUM('',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 130 ]; then sed -e "s/set[ ]*('[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*',/ENUM('',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 131 ]; then sed -e "s/set[ ]*('','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*',/ENUM('',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 132 ]; then sed -e "s/set[ ]*('','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*',/ENUM('',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 133 ]; then sed -e "s/set[ ]*('','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*','[a-zA-Z0-9]*',/ENUM('',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 134 ]; then sed -e "s/set[ ]*('','','','','','',/SET('',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 135 ]; then sed -e "s/set[ ]*('','','','',/SET('',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 136 ]; then sed -e "s/set[ ]*('','','',/SET('',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 137 ]; then sed -e "s/set[ ]*('','',/SET('',/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 138 ]; then sed -e "s/INNR/I/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 139 ]; then sed -e "s/OUTR/O/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 140 ]; then sed -e 's/[\t ]\+/ /g' -e 's/ \([;,]\)/\1/g' -e 's/ $//g' -e 's/^ //g' $WORKF > $WORKT
    elif [ $TRIAL -eq 141 ]; then sed -e 's/.*/\L&/' $WORKF > $WORKT
    elif [ $TRIAL -eq 142 ]; then sed -e 's/[ ]*([ ]*/(/;s/[ ]*)[ ]*/)/' $WORKF > $WORKT
    elif [ $TRIAL -eq 143 ]; then sed -e "s/;.*/;/" $WORKF > $WORKT
    elif [ $TRIAL -eq 144 ]; then NOSKIP=1; sed -e "s/TokuDB/InnoDB/gi" $WORKF > $WORKT
    elif [ $TRIAL -eq 145 ]; then sed "s/''/0/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 146 ]; then sed "/INSERT/,/;/s/''/0/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 147 ]; then sed "/SELECT/,/;/s/''/0/g" $WORKF > $WORKT
    elif [ $TRIAL -eq 148 ]; then grep -E --binary-files=text -v "^#|^$" $WORKF > $WORKT
    elif [ $TRIAL -eq 149 ]; then sed -e 's/0D0R0O0P0D0A0T0A0B0A0S0E0t0r0a0n0s0f0o0r0m0s0/NO_SQL_REQUIRED/' $WORKF > $WORKT
    elif [ $TRIAL -eq 150 ]; then NEXTACTION="& Finalize run"; sed 's/`//g' $WORKF > $WORKT
    else break
    fi
    SIZET=`stat -c %s $WORKT`
    if [ ${NOSKIP} -eq 0 -a $SIZEF -eq $SIZET ]; then 
      echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Skipping this trial as it does not reduce filesize"
    else
      if [ -f $WORKD/mysql.out ]; then echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Remaining size of input file: $SIZEF bytes ($LINECOUNTF lines)"; fi 
      run_and_check
      LINECOUNTF=`cat $WORKF | wc -l | tr -d '[\t\n ]*'`
      SIZEF=`stat -c %s $WORKF`
    fi
    TRIAL=$[$TRIAL+1]
  done
fi

#STAGE8: Execute mysqld option simplification. Perform a check if the issue is still present for each replacement (set)
if [ $SKIPSTAGEBELOW -lt 8 -a $SKIPSTAGEABOVE -gt 8 ]; then
  STAGE=8
  TRIAL=1
  echo $MYEXTRA | tr -s " " "\n" > $WORKD/mysqld_opt.out
  COUNT_MYEXTRA=`echo ${MYEXTRA} | wc -w`
  FILE1="$WORKD/file1"
  FILE2="$WORKD/file2"
  MYROCKS="--default-tmp-storage-engine=MyISAM --rocksdb --skip-innodb --default-storage-engine=RocksDB"
  myextra_check(){
    count_mysqld_opt=`cat $WORKD/mysqld_opt.out | wc -l`
    head -n $((count_mysqld_opt/2)) $WORKD/mysqld_opt.out > $FILE1
    tail -n $((count_mysqld_opt-count_mysqld_opt/2)) $WORKD/mysqld_opt.out > $FILE2
  }

  myextra_check

  #binary log server-id startup option check with 5.7 version
  logbin_startup_chk(){
    if [[ ! "$(${BASEDIR}/bin/mysqld --version | grep -E --binary-files=text -oe '5\.[567]|8\.[0]' | head -n1)" =~ ^5.[56]$ ]]; then
      if echo "${MYEXTRA}" | grep -E '\--log-bin'; then
        if ! echo "${MYEXTRA}" | grep -E '\--server-id'; then
          CHK_LOGBIN=1
        else
          CHK_LOGBIN=0
        fi
      fi
    else
      CHK_LOGBIN=0
    fi
  }

  myextra_reduction(){
    while read line; do
      NEXTACTION="& try removing next mysqld option"
      MYEXTRA=$(echo $MYEXTRA | sed "s|$line||")
      if [ "${STAGE8_CHK}" == "1" ]; then
        if [ "" != "$STAGE8_OPT" ]; then
          MYEXTRA=$(echo $MYEXTRA | sed "s|$STAGE8_OPT||")
        fi
      else
        MYEXTRA="$MYEXTRA ${STAGE8_OPT}"
      fi
      STAGE8_CHK=0
      COUNT_MYSQLDOPTIONS=`echo ${MYEXTRA} | wc -w`
      echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Filtering mysqld option $line from MYEXTRA";
      logbin_startup_chk
      run_and_check
      TRIAL=$[$TRIAL+1]
      STAGE8_OPT=$line
    done < $WORKD/mysqld_opt.out
  }

  if [ -n "$MYEXTRA" ]; then
    if [[ $COUNT_MYEXTRA -gt 3 ]]; then
      while true; do
        ISSUE_CHECK=0
        NEXTACTION="& try removing next mysqld option"
        MYEXTRA=$(cat $FILE1 | tr -s "\n" " ")
        logbin_startup_chk
        COUNT_MYSQLDOPTIONS=$(echo $MYEXTRA | wc -w)
        if [[ $COUNT_MYSQLDOPTIONS -eq 1 ]]; then
          echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Using $MYEXTRA mysqld option from MYEXTRA"
        else
          echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Using first set ${COUNT_MYSQLDOPTIONS} mysqld options from MYEXTRA: $MYEXTRA";
        fi
        run_and_check
        if [ "${STAGE8_CHK}" == "1" ]; then
          ISSUE_CHECK=1
          echo $MYEXTRA | tr -s " " "\n" > $WORKD/mysqld_opt.out
          myextra_check
        else
          MYEXTRA=$(cat $FILE2 | tr -s "\n" " ")
          logbin_startup_chk
          COUNT_MYSQLDOPTIONS=$(echo $MYEXTRA | wc -w)
          if [[ $COUNT_MYSQLDOPTIONS -eq 1 ]]; then
            echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Using $MYEXTRA mysqld option from MYEXTRA"
          else
            echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Using second set ${COUNT_MYSQLDOPTIONS} mysqld options from MYEXTRA: $MYEXTRA";
          fi
          run_and_check
          if [ "${STAGE8_CHK}" == "1" ]; then
            ISSUE_CHECK=1
            echo $MYEXTRA | tr -s " " "\n" > $WORKD/mysqld_opt.out
            myextra_check
          fi
        fi
        STAGE8_CHK=0
        COUNT_MYFILE=`cat $WORKD/mysqld_opt.out | wc -l`
        if [[ $COUNT_MYFILE -le 3 ]] || [[ $ISSUE_CHECK -eq 0 ]]; then
          myextra_reduction
          break
        fi      
        TRIAL=$[$TRIAL+1]
      done
    else
      myextra_reduction
    fi
  else
    echo_out "$ATLEASTONCE [Stage 8] Skipping this stage as it does not contain extra mysqld options." 
  fi
fi

#STAGE9: Execute storage engine option simplification.
if [ $SKIPSTAGEBELOW -lt 9 -a $SKIPSTAGEABOVE -gt 9 ]; then
  TRIAL=1
  STAGE=9
  if [[ -z $TOKUDB ]] && [[ -z $ROCKSDB ]]  ;then 
   echo_out "$ATLEASTONCE [Stage $STAGE] skipped as no additional storage engines were detected"
  else
    if [[ ! -z $TOKUDB ]] ;then
      echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Removing TokuDB storage engine from startup option"
      STAGE9_CHK=0
      SAFE_TOKUDB=$TOKUDB
      TOKUDB="";
      STAGE9_NOT_STARTED_CORRECTLY=0
      run_and_check
      if [ $STAGE9_CHK -eq 0 -o $STAGE9_NOT_STARTED_CORRECTLY -eq 1 ];then
        TOKUDB="$SAFE_TOKUDB"
      fi
      TRIAL=$[$TRIAL+1]
    fi
    if [[ ! -z $ROCKSDB ]];then
      echo_out "$ATLEASTONCE [Stage $STAGE] [Trial $TRIAL] Removing RocksDB storage engine from startup option"
      STAGE9_CHK=0
      SAFE_ROCKSDB=$ROCKSDB
      ROCKSDB="";
      STAGE9_NOT_STARTED_CORRECTLY=0
      run_and_check
      if [ $STAGE9_CHK -eq 0 -o $STAGE9_NOT_STARTED_CORRECTLY -eq 1 ];then
        ROCKSDB="$SAFE_ROCKSDB"
      fi
    fi
  fi
fi

finish $INPUTFILE
