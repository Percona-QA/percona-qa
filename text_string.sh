#!/bin/bash
# Created by Roel Van de Paar, Percona LLC
# Extracts the most relevant string from an error log, in this order:
# filename+line number > assertion message > first mangled c++ frame from error log stack (relatively inaccurate), in two different modes: (_ then (
# In principle, this order is not optimal. When it was instituted, it was not considered that filename+line number would be subject to decay (changing code)
# Yet, because known_bugs.strings exists, and it contains many bugs, it is thought best not to change the order now which would cause a lot of extra work
# now. The best way to workaround this issue is to scan the known_bugs.strings file for "approximately" matching line numbers and then check the corresponding
# bug report for similarity with the bug at hand.

# WARNING! If there are multiple crashes/asserts shown in the error log, remove the older ones (or the ones you do not want)

if [ "$1" == "" ]; then
  echo "$0 failed to extract string from an error log, as no error log file name was passed to this script"
  exit 1
fi

STRING=$(echo \
  $( \
    egrep -i 'Assertion failure.*in file.*line' $1 | sed 's|.*in file ||;s| |DUMMY|g'; \
    egrep 'Assertion.*failed' $1 | grep -v 'Assertion .0. failed' | sed 's/|/./g;s/\&/./g;s/"/./g;s/:/./g;s|^.*Assertion .||;s|. failed.*$||;s| |DUMMY|g'; \
    egrep 'libgalera_smm\.so\(_|mysqld\(_|ha_tokudb.so\(_' $1; \
    egrep 'libgalera_smm\.so\(|mysqld\(|ha_tokudb.so\(' $1 | egrep -v 'mysqld\(_|ha_tokudb.so\(_' \
  ) | \
  tr ' ' '\n' | \
  sed 's|.*libgalera_smm\.so[\(_]*||;s|.*mysqld[\(_]*||;s|.*ha_tokudb.so[\(_]*||;s|).*||;s|+.*$||;s|DUMMY| |g;s|($||;s|"|.|g;s|\!|.|g;s|&|.|g;s|\*|.|g;s|\]|.|g;s|\[|.|g;s|)|.|g;s|(|.|g' | \
  grep -v '^[ \t]*$' | \
  head -n1 | sed 's|^[ \t]\+||;s|[ \t]\+$||;' \
)

if [ "${STRING}" == "" -o "${STRING}" == "my_print_stacktrace" -o "${STRING}" == "0" -o "${STRING}" == "NULL" ]; then
  POTENTIALLY_BETTER_STRING="$(grep 'Assertion failure:' $1 | tail -n1 | sed 's|.*Assertion failure:[ \t]\+||;s|[ \t]+$||;s|.*c:[0-9]\+:||;s|"|.|g;s|\!|.|g;s|&|.|g;s|\*|.|g;s|\]|.|g;s|\[|.|g;s|)|.|g;s|(|.|g')"
  if [ "${POTENTIALLY_BETTER_STRING}" != "" -a "${POTENTIALLY_BETTER_STRING}" != "my_print_stacktrace" -a "${POTENTIALLY_BETTER_STRING}" != "0" -a "${POTENTIALLY_BETTER_STRING}" != "NULL" ]; then
    STRING=${POTENTIALLY_BETTER_STRING}
  fi
fi

echo ${STRING}
