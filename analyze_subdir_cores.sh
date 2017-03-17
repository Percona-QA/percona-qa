#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script analyzes core files in subdirectories (at any depth) and writes output to gdb_<core file name>_STD/_FULL.txt

echoit(){ echo "[$(date +'%T')] $1"; }

if [ "$1" == "" ]; then
  if [ -r ./mysqld/mysqld ]; then
    echoit "No mysqld location passed. However, this script found a local ./mysqld/mysqld binary, and assumed it was the one used for this run. GDB will use with this binary."
    echoit "If created stack traces look mangled/unresolved, check the mysqld binary used for the coredumps (in subdirectories), and pass it as the 1st option to this script."
    BIN="./mysqld/mysqld"
  else
    echo "This script analyzes core files in subdirectories and writes output to gdb_<core file name>_STD/_FULL.txt."
    echo "It expects one parameter: a full path pointer to the binary used to generate these core dumps. For example:"
    echo "$ cd my_work_dir; <your_percona-qa_path>/analyze_subdir_cores.sh /ssd/Percona-Server-5.6.14-rel62.0-508-debug.Linux.x86_64/bin/mysqld"
    exit 1
  fi
else
  BIN=$1
fi

for CORE in $(find . | grep "core") ; do
  COREFILE=$(echo $CORE | sed 's|[^/]*/||;s|\([^/]*\)\(.*\)|\1_\2|;s|/.*/||')
  echoit "Now processing core ${COREFILE}..."
  # For debugging purposes, remove ">/dev/null 2>&1" on the next line and observe output
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
echo 'More advanced version (note this may not work if your core file pattern is not set to core.%p.%u.%g.%s.%t.%e (search setup_server.sh for the same for how to do this):'
echo 'for FILE in $(ls *_STD.txt); do grep -HA11 "Thread 1 (" ${FILE} | grep -E "#4 |#5 |#6 " | tr -d "\n" | sed "s|0x[a-f0-9]\+ in ||g;s|.*\.14\([0-9]\+\)\..*#4[ ]\+\([\?:_a-zA-Z0-9]\+\) .*#5[ ]\+\([\?:_a-zA-Z0-9]\+\) \(.*\)|\2::\3::DUMMY\4DUMMY  14\1\n|;s|DUMMY.*#6[ ]\+\([\?:_a-zA-Z0-9]\+\) .*DUMMY|\1|;s|DUMMY||g"; done | sort -ut" " -k1,1'
echo 'This will print unique frame #4/5/6 issues with their 14<x> core name. Then search for the trial;'
echo 'find . | grep "1473897687"  # Trial number is subdir before the core file'
