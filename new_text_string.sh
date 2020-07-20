#!/bin/bash
# Created by Roel Van de Paar, MariaDB

# Exit codes in this script are significant; used by reducer.sh and potentially other scripts
# First option to this script can be;
# ./new_text_string.sh 'FRAMESONLY'    # Used in automation, ref mass_bug_report.sh
# ./new_text_string.sh "${mysqld_loc}" # Where mysqld

FRAMESONLY=0
MYSQLD=
if [ ! -z "${1}" ]; then
  if [ "${1}" == "FRAMESONLY" ]; then  # Used in automation, ref mass_bug_report.sh
    FRAMESONLY=1
  elif [ -r "${1}" -a -x "${1}" ]; then  # TODO: improve to check if it is mysqld
    MYSQLD="${1}"
  else
    echo "Assert: an option (${1}) was passed to this script, but that option does not make sense to this script"
    exit 1
  fi
fi

if [ -z "${MYSQLD}" ]; then
  if [ -r ./bin/mysqld -a ! -d ./bin/mysqld ]; then  # For direct use in BASEDIR, like ~/tt
    MYSQLD="./bin/mysqld"
  elif [ -r ../mysqld -a ! -d ../mysqld ]; then  # Used by pquery-run.sh when analyzing trial cores in-run
    MYSQLD="../mysqld"
  elif [ -r ../mysqld/mysqld -a ! -d ../mysqld/mysqld ]; then  # For direct use inside trial directories
    MYSQLD="../mysqld/mysqld"
  elif [ -r ./log/master.err ]; then
    POTENTIAL_MYSQLD="$(grep "ready for connections" ./log/master.err | sed 's|: .*||;s|^.* ||' | head -n1)"
    if [ -r ${POTENTIAL_MYSQLD} ]; then
      MYSQLD="${POTENTIAL_MYSQLD}"
    fi
  else
    echo "Assert: mysqld not found at ./bin/mysqld, nor ../mysqld, nor ../mysqld/mysqld"
    exit 1
  fi
fi

# The */ in the */*core* core search pattern is for to the /node1/ dir setup for cluster runs
LATEST_CORE=$(ls -t */*core* 2>/dev/null | grep -v 'PREV' | head -n1)  # Exclude data.PREV
if [ -z "${LATEST_CORE}" ]; then
  # TODO: Improve code for when there is an error log (with possible assert) but no core dump (unlikely)
  # Idea; can we fallback to OLD/text_string.sh in that case?
  echo "Assert: no core file found in */*core* (excluding any .PREV directories)"
  exit 1
fi

ERROR_LOG=$(ls log/master.err 2>/dev/null | head -n1)
if [ -z "${ERROR_LOG}" ]; then
  echo "Assert: no error log found at log/master.err - exiting"
  exit 1
fi

RANDOM=`date +%s%N | cut -b14-19`  # Random entropy init
RANDF=$(echo $RANDOM$RANDOM$RANDOM$RANDOM | sed 's|.\(..........\).*|\1|')  # Random 10 digits filenr

rm -f /tmp/${RANDF}.gdb*
gdb -q ${MYSQLD} ${LATEST_CORE} >/tmp/${RANDF}.gdb1 2>&1 << EOF
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

touch /tmp/${RANDF}.gdb3
TEXT=

# Assertion catch
# Assumes (which is valid for the pquery framework) that 1st assertion is also the last in the log
ASSERT="$(grep --binary-files=text -om1 'Assertion.*failed.$' ${ERROR_LOG} | sed "s|\.$||;s|^Assertion [\`]||;s|['] failed$||" | head -n1)"
if [ -z "${ASSERT}" ]; then
  ASSERT="$(grep --binary-files=text -m1 'Failing assertion:' ${ERROR_LOG} | sed "s|.*Failing assertion:[ \t]*||" | head -n1)"
fi
if [ ! -z "${ASSERT}" ]; then
  TEXT="${ASSERT}"
fi

# Signal catch
if grep -E --binary-files=text -iq 'Program terminated with' /tmp/${RANDF}.gdb1; then
  # sed 's|^\([^,]\+\),.*$|\1|' in the next line removes ", Segmentation fault" if "SIGSEGV" is present before it (and similar for other signals)
  SIG="$(grep 'Program terminated with' /tmp/${RANDF}.gdb1 | grep --binary-files=text -o 'with signal.*' | sed 's|with signal ||;s|\.$||' | sed 's|^\([^,]\+\),.*$|\1|' | head -n1)"
  if [ -z "${TEXT}" ]; then TEXT="${SIG}"; else TEXT="${TEXT}|${SIG}"; fi
elif grep -E --binary-files=text -iq '(sig=[0-9]+)' /tmp/${RANDF}.gdb1; then
  SIG="$(grep -o --binary-files=text '(sig=[0-9]\+)' /tmp/${RANDF}.gdb1 | sed 's|(||;s|)||' | head -n1)"
  if [ -z "${TEXT}" ]; then TEXT="${SIG}"; else TEXT="${TEXT}|${SIG}"; fi
fi
rm -f /tmp/${RANDF}.gdb1

# Stack catch
grep --binary-files=text -A100 'signal handler called' /tmp/${RANDF}.gdb2 | grep --binary-files=text -vE '__GI_raise |__GI_abort |__assert_fail_base |__GI___assert_fail |memmove|memcpy|\?\? \(\)|\(gdb\)|signal handler called' | sed 's|^#[0-9]\+[ \t]\+||' | sed 's|(.*) at ||;s|:[ 0-9]\+$||' > /tmp/${RANDF}.gdb4
rm -f /tmp/${RANDF}.gdb2

# Cleanup do_command and higher frames, provided sufficient frames will remain
DC_LINE="$(grep --binary-files=text -n '^do_command' /tmp/${RANDF}.gdb4)"
DC_CLEANED=0
if [ ! -z "${DC_LINE}" ]; then
  DC_LINE=$(echo ${DC_LINE} | grep --binary-files=text -o '^[0-9]\+')
  if [ ! -z "${DC_LINE}" ]; then
    # Reduce stack lenght if there are at least 5 descriptive frames
    if [ ${DC_LINE} -ge 5 ]; then
      grep --binary-files=text -B100 '^do_command' /tmp/${RANDF}.gdb4 | grep --binary-files=text -v '^do_command' > /tmp/${RANDF}.gdb3
      DC_CLEANED=1
    fi
  fi
fi
if [ ${DC_CLEANED} -eq 0 ]; then
  cat /tmp/${RANDF}.gdb4 > /tmp/${RANDF}.gdb3
fi
rm -f /tmp/${RANDF}.gdb4

# Grap first 4 frames, if they exist, and add to TEXT
FRAMES="$(cat /tmp/${RANDF}.gdb3 | head -n4 | sed 's| [^ ]\+$||' | tr '\n' '|' | sed 's/|$/\n/')"
rm -f /tmp/${RANDF}.gdb3
if [ ! -z "${FRAMES}" ]; then
  if [ ${FRAMESONLY} -eq 1 -o -z "${TEXT}" ]; then
    TEXT="${FRAMES}"
  else
    TEXT="${TEXT}|${FRAMES}"
  fi
else
  echo "Assert: No parsable frames?"
  exit 1
fi

# Report bug identifier string
if [ "$(echo "${TEXT}" | sed 's|[ \t]*\(.\).*|\1|')" == "#" ]; then
  echo "Assert: leading character of unique bug id (${TEXT}) is a '#', which will lead to issues in other scripts. This would normally never happen, but it did. Please improve new_text_string.sh to handle this situation!"
  exit 1
else
  echo "${TEXT}"
  exit 0
fi
