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

# The 4 egreps are individual commands executed in a subshell of which the output is then combined and processed further
# Be not misled by the 'libgalera_smm' start of the egrep. note the OR (i.e. '|') in the egreps; mysqld(_ is also scanned for, etc.
# This code block CAN NOT be changed without breaking backward compatibility, unless ALL bugs in known_bugs.strings are re-string'ed
STRING="$(echo "$( \
    egrep -i 'Assertion failure.*in file.*line' $1 | sed 's|.*in file ||;s| |DUMMY|g'; \
    egrep 'Assertion.*failed' $1 | grep -v 'Assertion .0. failed' | sed 's/|/./g;s/\&/./g;s/"/./g;s/:/./g;s|^.*Assertion .||;s|. failed.*$||;s| |DUMMY|g'; \
    egrep 'libgalera_smm\.so\(_|mysqld\(_|ha_rocksdb.so\(_|ha_tokudb.so\(_' $1; \
    egrep 'libgalera_smm\.so\(|mysqld\(|ha_rocksdb.so\(|ha_tokudb.so\(' $1 | egrep -v 'mysqld\(_|ha_rocksdb.so\(_|ha_tokudb.so\(_' \
  )" \
  | tr ' ' '\n' | \
  sed 's|.*libgalera_smm\.so[\(_]*||;s|.*mysqld[\(_]*||;s|.*ha_rocksdb.so[\(_]*||;s|.*ha_tokudb.so[\(_]*||;s|).*||;s|+.*$||;s|DUMMY| |g;s|($||;s|"|.|g;s|\!|.|g;s|&|.|g;s|\*|.|g;s|\]|.|g;s|\[|.|g;s|)|.|g;s|(|.|g' | \
  grep -v '^[ \t]*$' | \
  head -n1 | sed 's|^[ \t]\+||;s|[ \t]\+$||;' \
)"

check_better_string(){
  BETTER_FOUND=0
  if [ "${POTENTIALLY_BETTER_STRING}" != "" -a "${POTENTIALLY_BETTER_STRING}" != "my_print_stacktrace" -a "${POTENTIALLY_BETTER_STRING}" != "0" -a "${POTENTIALLY_BETTER_STRING}" != "NULL" ]; then
    STRING=${POTENTIALLY_BETTER_STRING}
    BETTER_FOUND=1
  fi
}

# This block can be added unto with 'ever deeper nesting if's' - i.e. as long as the output is poor (for the cases covered), more can
# be done to try and get a better quality string. Adding other "poor outputs" is also possible, though not 100% (as someone may have
# already added that particular poor output to known_bugs.strings - always check that file first, especially the TEXT=... strings
# towards the end of that file).
if [ "${STRING}" == "" -o "${STRING}" == "my_print_stacktrace" -o "${STRING}" == "0" -o "${STRING}" == "NULL" ]; then
  POTENTIALLY_BETTER_STRING="$(grep 'Assertion failure:' $1 | tail -n1 | sed 's|.*Assertion failure:[ \t]\+||;s|[ \t]+$||;s|.*c:[0-9]\+:||;s/|/./g;s/\&/./g;s/:/./g;s|"|.|g;s|\!|.|g;s|&|.|g;s|\*|.|g;s|\]|.|g;s|\[|.|g;s|)|.|g;s|(|.|g')"
  check_better_string
  if [ ${BETTER_FOUND} -eq 0 ]; then 
    # Last resort; try to get first frame from stack trace in error log in a more basic way
    # This may need some further work, if we start seeing too generic strings like 'do_command', 'parse_sql' etc. text showing in bug list
    POTENTIALLY_BETTER_STRING="$(egrep -o 'libgalera_smm\.so\(.*|mysqld\(.*|ha_rocksdb.so\(.*|ha_tokudb.so\(.*' $1 | sed 's|[^(]\+(||;s|).*||;s|(.*||;s|+0x.*||' | egrep -v 'my_print_stacktrace|handle.*signal|^[ \t]*$' | sed 's/|/./g;s/\&/./g;s/:/./g;s|"|.|g;s|\!|.|g;s|&|.|g;s|\*|.|g;s|\]|.|g;s|\[|.|g;s|)|.|g;s|(|.|g' | head -n1)"
    check_better_string
    # More can be added here, always preceded by: if [ ${BETTER_FOUND} -eq 0 ]; then
  fi
fi

if [ $(echo ${STRING} | wc -l) -gt 1 ]; then 
  echo "ASSERT! TEXT STRING WAS MORE THEN ONE LINE. PLEASE FIX ME (text_string.sh). NOTE; AS PER INSTRUCTIONS IN FILE, PLEASE AVOID EDITING THE ORIGINAL CODE BLOCK!"
  exit 1
fi

echo ${STRING}
