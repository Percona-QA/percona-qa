#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

if [ "" == "$1" ]; then
  echo "This script outputs the extra mysqld options used in a given RQG trial. It expects one parameter: the trial number to analyze. Ensure that startup.sh has already been executed for this trial."
  exit 1
else
  TRIAL=$1
  if [ ! -r ./cmdtrace${TRIAL} ]; then
    echo "Assert: ./cmdtrace${TRIAL} does not exist or cannot be read?"
    echo "Try running ${SCRIPT_PWD}/startup.sh ${TRIAL} to generate ./cmdtrace${TRIAL}"
    exit 1
  fi
fi

# Compile 'mysqld options used' string
MYEXTRA=`cat ./cmdtrace${TRIAL} | sed 's|--mysqld=|\nOPT|g' | grep "^OPT" | sed 's| .*||;s|^OPT||' | tr '\n' ' ' | sed 's|^[ \t]*|MYEXTRA="--log-output=none |;s|[ \t]*$|"\n|'`
MYEXTRA=`echo $MYEXTRA | sed "s|'||g"`  # Fixes --plugin-load='audit_log=audit_log.so;tokudb=ha_tokudb.so' (removes quotes, which works fine for mysqld)
MYEXTRA=`echo $MYEXTRA | sed 's|--log-output=[A-Za-z]*[ ]*||'`
MYEXTRA=`echo $MYEXTRA | sed 's|--general_log[ ]*||'`
MYEXTRA=`echo $MYEXTRA | sed 's|--general_log_file=[^ ]*.sql[ ]*||'`
if `echo $MYEXTRA | grep -qi "innodb_log_block_size"` ;then
  # Example bug reference: https://bugs.launchpad.net/percona-server/+bug/1263253 (innodb_log_block_size causes issues)
  MYEXTRA=`echo $MYEXTRA | sed 's|--innodb_log_block_size=[0-9]*[ ]*--|--|'`
  echo "* Reproducibility warning: innodb_log_block_size was present/set in the RQG run. This may cause issues for reducer.sh. This script has auto-removed this mysqld setting from the MYEXTRA setting in the resulting reducer script ./reducer${TRIAL}.sh, but please see if the issue reproduces. If it does not reproduce, AND the cause is this auto-removed mysqld setting, we need to extend reducer.sh so it handles changed innodb_log_block_size correctly (which basically entails letting reducer.sh use innodb_log_block_size even in the initial round where reducer.sh prepares a data directory)."
fi
if `echo $MYEXTRA | grep -qi "_epoch"` ;then
  # When _epoch directories are used in the RQG run then reducer.sh will not (yet) create it's own fresh ones (it will just use the mysqld setting as-is
  # and thus likely fail to even start if _epoch directories are present). Hence, we are auto-removing them at this point in time as they are highly
  # likely not needed for issue reproducibility (unless an issue is caused by a changed log_arch or log_group_home directory - which as said is unlikely)
  # If an improvement has to be made here (i.e. we find that at least a few issues are caused by a changed log_arch or log_group_home directory then
  # such a change would best be made in reducer.sh itself; if _epoch text/dir found in options then swap the dirory, create clean dir in trial dir
  # (as it needs to be actioned for each trial reducer.sh runs - reducer.sh trials this is, not RQG trials)

  # Note that if in the future _epoch use is extended in RQG grammars, this section needs additional MYEXTRA replacements for those mysqld options):
  MYEXTRA=`echo $MYEXTRA | sed 's|--innodb_log_arch_dir=[^ ]*_epoch.[^ ]*[ ]*||'`
  MYEXTRA=`echo $MYEXTRA | sed 's|--innodb_log_group_home_dir=[^ ]*_epoch.[^ ]*[ ]*||'`
  echo "* Reproducibility warning: an _epoch directory (in --innodb_log_arch_dir or --innodb_log_group_home_dir) was present/set in the RQG run. This may cause issues for reducer.sh. This script has auto-removed thisi/these mysqld setting(s) from the MYEXTRA setting in the resulting reducer script ./reducer${TRIAL}.sh, but please see if the issue reproduces. If it does not reproduce, AND the cause is this auto-removed mysqld setting, we need to extend reducer.sh so it handles _epoch directories correctly. See ./cmdtrace${TRIAL} for the actual settings removed (--innodb_log_arch_dir and/or --innodb_log_group_home_dir)"
fi
echo "-------- FINAL OPTIONS USED --------"
echo "$MYEXTRA"
echo "------------------------------------"
