#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script analyzes core files in subdirectories (at any depth) and writes output to gdb_<core file name>_STD/_FULL.txt

if [ "$1" == "" ]; then
  echo "This script analyzes core files in subdirectories and writes output to gdb_<core file name>_STD/_FULL.txt."
  echo "It expects one parameter: a full path pointer to the binary used to generate these core dumps. For example:"
  echo "$ cd my_work_dir; <your_percona-qa_path>/analyze_subdir_cores.sh /ssd/Percona-Server-5.6.14-rel62.0-508-debug.Linux.x86_64/bin/mysqld"
  exit 1
else
  BIN=$1
fi

echoit(){
  echo "[$(date +'%T')] $1"
}

for CORE in $(find . | grep "core.*") ; do
  # For debugging purposes, remove ">/dev/null 2>&1" on the next line and observe output
  COREFILE=$(echo $CORE | sed 's|data.\([0-9]*\).|core_data.\1_|' | sed 's|.*core|core|')
  echoit "Now processing core ${COREFILE}..."
  gdb ${BIN} ${CORE} >/dev/null 2>&1 <<EOF
    # Avoids libary loading issues / more manual work, see bash$ info "(gdb)Auto-loading safe path"
    set auto-load safe-path /         
    # See http://sourceware.org/gdb/onlinedocs/gdb/Threads.html - this avoids the following issue:
    # "warning: unable to find libthread_db matching inferior's threadlibrary, thread debugging will not be available"
    set libthread-db-search-path /usr/lib/
    set trace-commands on
    set pagination off
    set print pretty on
    set print array on
    set print array-indexes on
    set print elements 4096
    set logging file gdb_${COREFILE}_FULL.txt
    set logging on
    thread apply all bt full
    set logging off
    set logging file gdb_${COREFILE}_STD.txt
    set logging on
    thread apply all bt
    set logging off
    quit
EOF
done;

echo "Done!"
echo "P.S. To quickly check what the cores are for, use (note: this provides a highly condensed list which may miss some similar issues):"
echo 'grep -A 20 "Thread 1 (" *_STD.txt | sed "s|(.*)|(...)|g" | grep "#[4-6]" | egrep -v "assert|abort" | grep " in " | sed "s|.* in|in|" | sort -u'
echo 'or:'
echo 'grep -A 20 "Thread 1 (" *_STD.txt | grep "#[4-6]" | egrep -v "assert|abort" | grep " in " | sed "s|.* in|in|" | sort -u'
echo 'or:'
echo 'grep -A 20 "Thread 1 (" *_STD.txt | grep "#[4-6]" | egrep -v "assert|abort"'
echo 'for tokudb issues, use:'
echo 'grep -A 20 "Thread 1 (" *_STD.txt | grep "#[4-6]" | grep " in " | sed "s|.* in|in|" | sort -u'
echo 'or:'
echo 'grep -A 20 "Thread 1 (" *_STD.txt | grep "#[4-6]"'
echo '-----'
echo 'Then, once you have the desired string to look for, search for it to see what trials had the issue. E.g. (For example: "Sql_condition::message_text");'
echo 'find . | grep $(grep "Sql_condition::message_text" *_STD.txt | sed "s|:.*||;s|_STD.txt||;s|.*_||" | head -n1)'

