#!/bin/bash
# Created by Roel Van de Paar, MariaDB

LATEST_CORE=$(ls -t data/*core* 2>/dev/null | head -n1)
if [ -z "${LATEST_CORE}" ]; then
  echo "No core file found in data/*core* - exiting"
  exit 1
fi

RANDOM=`date +%s%N | cut -b14-19`  # Random entropy init
RANDF=$(echo $RANDOM$RANDOM$RANDOM | sed 's|.\(.......\).*|\1|')  # Random 7 digits filenumber

rm -f /tmp/${RANDF}.gdb*
gdb -q bin/mysqld $(ls data/*core*) >/tmp/${RANDF}.gdb1 2>&1 << EOF
  set pagination off
  set trace-commands off
  set frame-info short-location
  bt
  set print frame-arguments none
  set print repeats 0
  set print max-depth 0
  set print null-stop
  set print demangle on
  set print object off
  set print static-members off
  set print address off
  set print symbol-filename off
  set print symbol off
  set filename-display basename 
  set print array off
  set print array-indexes off
  set print elements 1
  set logging file /tmp/${RANDF}.gdb2
  set logging on
  bt
  set logging off
  quit
EOF

# Signal catch
grep 'Program terminated with' /tmp/${RANDF}.gdb1 | grep -o 'with signal.*' | sed 's|with signal ||;s|\.$||' > /tmp/${RANDF}.gdb3
rm -f /tmp/${RANDF}.gdb1

# Stack catch
grep -A100 'signal handler called' /tmp/${RANDF}.gdb2 | grep -vE '(gdb)|signal handler called' | sed 's|^#[0-9]\+[ \t]\+||' | sed 's|(.*) at ||;s|:[ 0-9]\+$||' > /tmp/${RANDF}.gdb4
rm -f /tmp/${RANDF}.gdb2

# Cleanup do_command if sufficient frames will remain
DCLINE=$(grep -n '^do_command' /tmp/${RANDF}.gdb4)
DCCLEANED=0
if [ ! -z "${DCLINE}" ]; then
  DCLINE=$(echo ${DCLINE} | grep -o '^[0-9]\+')
  if [ ! -z "${DCLINE}" ]; then
    # Reduce stack lenght if there are at least 5 descriptive frames
    if [ ${DCLINE} -ge 5 ]; then
      grep -B100 '^do_command' /tmp/${RANDF}.gdb4 | grep -v '^do_command' >> /tmp/${RANDF}.gdb3
      DCCLEANED=1
    fi
  fi
fi
if [ ${DCCLEANED} -eq 0 ]; then
  cat /tmp/${RANDF}.gdb4 >> /tmp/${RANDF}.gdb3
fi
rm -f /tmp/${RANDF}.gdb4

cat /tmp/${RANDF}.gdb3
rm -f /tmp/${RANDF}.gdb3
