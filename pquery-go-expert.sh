#!/bin/bash
# Created by Roel Van de Paar, Percona LLC
# You can start this script from within a pquery working directory, and it will - every 10 minutes - prepare reducer's, cleanup known issues, and display the results of the
# current run. Recommended to run this inside a screen session (alike to pquery-run.sh running in a screen session), so that your hdd/ssd does not run out of space, and so
# reducer scripts are ready when needed. This script furthermore modifies some more expert reducer.sh settings which aid in mass-bug handling, though they require some more
# manual work once reductions are nearing completion;
# FORCE_SKIPV is set to 1
# FORCE_KILL is set to 1, for MODE=3 and MODE=4 issues only: better and faster reduction, though misses some shutdown errors (may need a bit of tweaking for some trials to get it to reproduce in that case), though most of those cases (which are likely rare to start with) are now covered below, search for SHUTDOWN_OFFSET and see surrounding code.
# MULTI_THREADS is set to 3
# MULTI_THREADS_INCREASE is set to 3
# MULTI_THREADS_MAX is set to 9
# STAGE1_LINES is set to 5  # This was previously 13, which is better for stable systems, as it will allow reducer to continue towards auto-pge. Auto-pge (i.e. all other stages after stage 1, as can also be set/done by calling ~/pge) is good for non-sporadic issues as it will drop any uncessary lines after stage 1 in stage 2. However, it is not good for sporadic issues as this will leave regularly 5-10 lines in the testcase which are not needed, requiring one to lower the number of STAGE1_LINES and re-running reducer. The tradeoff however is that one needs to be more diligent in checking runs and regularly CTRL+C > ~/pge for trials which have reduced to a large number of lines. To reach some 'ideal' tradeoff between the two, for the moment 5 was chosen. This will still require some trials (i.e. the non-sporadic ones) to be CTRL+C > ~/pge'd, and some trials (the sporadic ones) where STAGE1_LINES needs to be set lower. Ideally, at some point, an auto-restart-reducers script may be best where FORCE_SKIPV is tested and changes are made based on the result. Thinking about it, it may be better to include this functionality in reducer itself. The risk is that the issue does not reproduce even on 50 threads (auto-increased). To counter this, another type of STAGE V may be implemented; one which executes the testcase up to 10000 times. This is slow however, and then perhas the current system is best; rely on the skill of the engineer to see difference between sporadic/non-sporadic.
# INPUTFILE is auto-optimized towards latest sql trace inc _out* handling
# The effect of FORCE_SKIPV=1 is that reducer will skip the verify stage, start reduction immediately, using 3 threads (MULTI_THREADS=3), and never increases the set amount of
# threads (result of using FORCE_SKIPV=1). Note that MULTI_THREADS_INCREASE is only relevant for non-FORCE_SKIPV runs, more on why this is changed then below.
# In short, the big benefit of making these settings is that (assuming you are doing a standard single (client) threaded run) you can easily start 10-20 reducers, as each of
# those will now only start a maximum of 3 (MULTI_THREADS) threads to reduce each individual trial. There is no possibility for 'runaway' reducers that will take up to
# MULTI_THREADS_MAX threads (which by default means MULTI_THREADS=10, MULTI_THREADS_INCREASE=5 up to the maximum of MULTI_THREADS_MAX=50). Sidenote: While your system may be able to handle one of such reducer's running 50 threads, it would very unlikely handle more then 1-3 of those. In other words, and to summarize, if you start 10 reducers (10 trials
# being reduced at once), it will only use 30x mysqld (10 reducers, up to 3 mysqld's, i.e. MULTI_THREADS, each).
#  (Note however that if you had a multi-threaded run (i.e. THREADS=x in pquery-run.sh), then there are other considerations; firstly, PQUERY_MULTI would come into play. For true
#   multi-threaded reduction, you would turn this on. Secondly, turning that on means that PQUERY_MULTI_CLIENT_THREADS also comes into play: the number of client threads PER
#   mysqld. iow: watch server resources)
# Finally, why is MULTI_THREADS_INCREASE being set to 3 instead of the default 5? This brings us also to what is mentioned above: "require some more manual work reductions are
# nearing completion" IOW; when you started 10-20 reducers, a number of them will "just sit there" and not reduce: fine, they need extra work (ref
# reproducing_and_simplification.txt and check manually in logs what is happening etc.). For the reducers that HAVE reduced (hopefully the majority), you'll see that they get
# "stuck" at around 5 lines remaining. This is normal; due to enabling FORCE_SKIPV, it is in an infinite loop to reduce the testcases down to 3 lines (not going to happen in most
# cases) before it will continue. So, CTRL+C them, open up the matching reducer<nr>.sh file, set the (scroll about 3-4 screens down to the #VARMOD# section assuming you used
# pquery-prep-red.sh) INPUTFILE to "<existing name>_out" (the reduced testcase is named <existing name>_out by reducer, iow it gets the _out suffix) and turn FORCE_SKIPV to 0.
# Now reducer will first verify the issue (VERIFY stage i.e. V is no longer FOCE skipped now) and then it will go through the normal stages 1,2,3, etc.
# The likeliness of the VERIFY stage succeeding here is very high; the input testcase is now only 5 lines, it already has reproduced many times, and there is unlikely to be
# something amiss in the now-small SQL which causes non-reproducibilty, most other SQL has been filtered out already. STILL, IT IS POSSIBLE that the issue does not reproduce.
# Now reducer will stay in MULTI mode and, having started with MULTI_THREADS for the verify stage (sidenote: it would stop being in MULTI mode if all those MULTI threads
# reproduced the issue in the verify stage, i.e. the issue is not sporadic), and not having found the issue at all (for example), it will add MULTI_THREADS_INCREASE threads
# (3+3=6) and try again. Again, all this up to a maximum of MULTI_THREADS_MAX, which by default is 50. Now, to reduce the possibility of one starting with 10-20 reducers, then
# stopping a set of them, setting FORCE_SKIPV=0, and starting to reduce them again to get the optimal testcase, but running into the situation where the VERIFY stage is not able
# to reproduce the issue at all, and thus cause a set of 'runaway' reducers, MULTI_THREADS_MAX is set to 9, and MULTI_THREADS_INCREASE is set to 3. As MULTI_THREADS_MAX only
# becomes relevant later in the process, by that time a number of other server resources have likely freed up. IOW, the reason why all this is done is to avoid a situation where
# you are doing x amount of work, then your server hangs, and it's a mess to sort out :) (tip: if this happens, search like this: $ ls ./*_out )
#  (Sidenote: in the case where reduced does detect the issue but not in all the MULTI_THREADS threads, it will assume the issue sporadic, and hence a situation quite alike to
#   FORCE_SKIPV=1 is auto-set. In that case, go CTRL+_C and be happy with the thus-far (~5 lines) testcase, and post it to a bug using the created <epoch> scripts (_init, _start,
#   _cl, _run, _run_pquery etc.) - just use the generated tarball and copy in the <epoch>_how_to_reproduce.txt text into the bug report - sporadic issues are perhaps best handled
#   like this as the reproducer scrips are a neat/tidy way of reproducing the issue for the developers by only change the base directory in <epoch>_mybase)
# Hope that all of the above makes sense :), ping me if it does not :)

PID=
ctrl_c(){
  if [ "${PID}" != "" ]; then      # Ensure background process of background_sed_loop() is terminated
    kill -9 ${PID} >/dev/null 2>&1
  fi
  if [ "${REDUCER}" != "" ]; then  # Cleanup last reducer being worked on as it may have been incomplete
    rm -f ${REDUCER}
  fi
  echo "CTRL+c was pressed. Terminating."
  exit 1
}
trap ctrl_c SIGINT

# Internal variables
SCRIPT_PWD=$(cd "`dirname $0`" && pwd)
RANDOMMUTEX=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')
MUTEX=/tmp/pge_${RANDOMMUTEX}_IN_PROGRESS_MUTEX

# Check that this is not being executed from the SCRIPT_PWD (which would mess up the real reducer.sh
if [ "${PWD}" == "${SCRIPT_PWD}" ]; then
  echo "Assert: you cannot execute this script from within mariadb-qa. Please change to the pquery-run.sh work directory!"
  exit 1
elif [ ! -r ./pquery-run.log ]; then
  if [ "$1" != "force" ]; then
    echo "Assert: ./pquery-run.log not found. Are you sure this is a pquery-run.sh work directory? If so, to proceed, execute this script with 'force' as the first argument."
    exit 1
  fi
fi

background_sed_loop(){  # Update reducer<nr>.sh scripts as they are being created (a background process avoids the need to wait untill all reducers are created)
  while [ true ]; do
    touch ${MUTEX}                                  # Create mutex (indicating that background_sed_loop is live)
    sleep 2                                         # Ensure that we have a clean mutex/lock which will not be terminated by the main code anymore (ref: do sleep 1)
    for REDUCER in $(ls --color=never reducer*.sh quick_reducer*.sh 2>/dev/null); do
      if egrep -q '^finish .INPUTFILE' ${REDUCER}; then  # Ensure that pquery-prep-red.sh has fully finished writing this file (grep is for a string present on the last line only)
        if ! grep --binary-files=text -q '^.DONEDONE' ${REDUCER}; then       # Ensure that we're only updating files that were not updated previously (and possibly subsequently edited manually)
          sed -i "s|^FORCE_SKIPV=0|FORCE_SKIPV=1|" ${REDUCER}
          sed -i "s|^MULTI_THREADS=[0-9]\+|MULTI_THREADS=3 |" ${REDUCER}
          sed -i "s|^MULTI_THREADS_INCREASE=[0-9]\+|MULTI_THREADS_INCREASE=3|" ${REDUCER}
          sed -i "s|^MULTI_THREADS_MAX=[0-9]\+|MULTI_THREADS_MAX=9 |" ${REDUCER}
          sed -i "s|^STAGE1_LINES=[0-9]\+|STAGE1_LINES=5|" ${REDUCER}
          # Auto-set the inputfile to the most recent sql trace inc _out* handling
          # Also exclude 'backup/failing' for multi-threaded runs. For example, WORKDIR/TRIALDIR/trial.sql.failing (/data/487127/48/48.sql.failing)
          sed -i 's|^INPUTFILE="\([^"]\+\)"|INPUTFILE="$(ls -t \1* \| grep --binary-files=text -vE "backup\|failing" \| head -n1)"|' ${REDUCER}
          # Next, we consider if we will set FORCE_KILL=1 by doing many checks to see if it makes sense
          if grep --binary-files=text -qiE "^MODE=3|^MODE=4" ${REDUCER}; then  # Mode 3 or 4 (and not 0)
            TRIAL="$(echo ${REDUCER} | grep -o '[0-9]\+')"
            if [ ! -r "./${TRIAL}/AVOID_FORCE_KILL" ]; then  # Not flagged by pquery-prep-red.sh as a trial for which AVOID_FORCE_KILL should be avoided (i.e. likely a trial for which SHUTDOWN_TIMEOUT_ISSUE was previously found/set, but also with a core dump present - i.e. actual shutdown IS required to reduce towards the core dump issue seen)
              if [ ! -r "./${TRIAL}/SHUTDOWN_TIMEOUT_ISSUE" ]; then  # Not a shutdown timeout issue
                TERRIBLY_OFFSET=$(grep --binary-files=text -ihbm1 'terribly' ${TRIAL}/log/master.err | head -n1 | sed 's|^\([0-9]\+\).*|\1|')
                SHUTDOWN_OFFSET=$(grep --binary-files=text -hb 'shutdown' ${TRIAL}/log/master.err | grep -v srv_shutdown | head -n1 | sed 's|^\([0-9]\+\).*|\1|')
                if [ ! -z "${TERRIBLY_OFFSET}" -a ! -z "${SHUTDOWN_OFFSET}" ]; then
                  if [ ${TERRIBLY_OFFSET} -lt ${SHUTDOWN_OFFSET} ]; then  # Ensure crash came before shutdown
                    sed -i "s|^FORCE_KILL=[0-9]\+|FORCE_KILL=1|" ${REDUCER}
                  fi
                elif [ -z "${SHUTDOWN_OFFSET}" ]; then  # No shutdown seen; safe to proceed
                  sed -i "s|^FORCE_KILL=[0-9]\+|FORCE_KILL=1|" ${REDUCER}
                fi
              fi
            fi
            TRIAL=;TERRIBLY_OFFSET=;SHUTDOWN_OFFSET=
          fi 
          echo '#DONEDONE' >> ${REDUCER}
        fi
      fi
    done
    REDUCER=                                        # Clear reducer variable to avoid last reducer being deleted in ctrl_c() if it WAS complete (which at this point it would be)
    rm ${MUTEX}                                     # Remove mutex (allowing this function to be terminated by the main code)
    sleep 4                                         # Sleep 4 seconds (allowing this function to be terminated by the main code)
  done
  PID=
}

while(true); do                                     # Main loop
  while(true); do                                   # Prevent a bug when pquery-go-expert.sh is started and no trials are present yet
    if [ "$(ls -d [0-9]* 2>/dev/null)" == "" ]; then
      echo "Waiting for next round... Sleeping 300 seconds..."
      sleep 300                                     # Sleep 5 minutes
      continue
    else
      break
    fi
  done
  touch ${MUTEX}                                    # Create mutex (indicating that background_sed_loop is live)
  if [ `ls */*.sql 2>/dev/null | wc -l` -gt 0 ]; then  # If trials are available
    background_sed_loop &                           # Start background_sed_loop in a background thread, it will patch reducer<nr>.sh scripts
    PID=$!                                          # Capture the PID of the background_sed_loop so we can kill -9 it once pquery-prep-red.sh is complete
    ${SCRIPT_PWD}/pquery-prep-red.sh                # Execute pquery-prep.red generating reducer<nr>.sh scripts, auto-updated by the background thread
    echo -e "\nCleaning up known issues..."
    ${SCRIPT_PWD}/pquery-clean-known.sh             # Clean known issues
    ${SCRIPT_PWD}/pquery-clean-known++.sh           # Expert clean known issues (quite strong cleanup)
    ${SCRIPT_PWD}/pquery-eliminate-dups.sh          # Eliminate dups, leaving at least x trials for issues where the number of trials >=x. Will also leave alone all other (<x) trials. x can be set in script
  fi
  if [ $(ls reducer*.sh quick_reducer*.sh 2>/dev/null | wc -l) -gt 0 ]; then  # If reducers are available after cleanup
    echo ""
    ${SCRIPT_PWD}/pquery-results.sh                 # Report
  fi
  while [ -r ${MUTEX} ]; do sleep 1; done           # Ensure kill of background_sed_loop only happens when background process has just started sleeping
  kill -9 ${PID} >/dev/null 2>&1                    # Kill the background_sed_loop
  echo "Waiting for next round... Sleeping 300 seconds..."
  sleep 300                                         # Sleep 5 minutes
done
