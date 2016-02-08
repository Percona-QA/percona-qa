#!/bin/bash
# Created by Roel Van de Paar Percona LLC
# Extracts the most relevant Valgring string from of an error log

if [ "$1" == "" ]; then
  echo "$0 failed to extract a valgrind string from an error log, as no error log file name was passed to this script"
  exit 1
fi

# List of strings to filter (too generic)
filter=('???' 'malloc' 'my_malloc' 'alloc_root' 'multi_alloc_root' 'free' 'my_free' 'my_hash_free' 'my_strndup' 'strmake_root' 'strdup_root' 'ut_free' 'free_root' 'realloc' 'calloc' 'my_realloc' 'je_arena_ralloc' 'je_arena_dalloc_large' 'je_arena_dalloc_small' 'je_tcache_bin_flush_large' 'je_tcache_bin_flush_small' 'je_tcache_event_hard' 'DbugMalloc' 'delete_dynamic' 'my_hash_free_elements' 'my_hash_free' 'mem_area_free' 'mem_heap_block_free' 'mem_heap_free_func' 'mem_free_func' 'mem_area_alloc' 'mem_heap_create_block' 'mem_heap_create_func' 'mem_alloc_func' 'memcpy')

check_string(){
  FLAG_GOOD=1
  for CHECK_STRING in "${filter[@]}"; do
    if [ "${CHECK_STRING}" == "${STRING}" ]; then
      FLAG_GOOD=0
      break
    fi
  done
}

# Grab "at 0x" - the most precise frame in a Valgrind stack (but it may be too general/generic, hence filtering is in place)
STRING=`grep -m1 "^[ \t]*==[0-9]\+[= \t]\+at[ \t]*0x" $1 | sed 's|(.*||;s|.*: ||;s|^[ \t]*||;s|[ \t]*$||'`
if [ "${STRING}" == "" ]; then
  echo "NO VALGRIND STRING FOUND: There was likely no Valgrind error in this run (manually check $1)"
  exit 2
fi
if [ "${STRING}" != "???" ]; then
  BACKUP_VALGRIND_STRING=${STRING}
fi
check_string
if [ ${FLAG_GOOD} -eq 1 ]; then
  VALGRIND_STRING=${STRING}
else
  for i in $(seq 1 10); do
    # If "at 0x" was too generic (=filtered out), grab a more detailed "by 0x" frame from the Valgrind stack, try up to 10 times to get a non-filtered frame
    STRING=`grep "^[ \t]*==[0-9]\+[= \t]\+by[ \t]*0x" $1 | sed 's|(.*||;s|.*: ||;s|^[ \t]*||;s|[ \t]*$||' | head -n$i | tail -n1`
    if [ "${BACKUP_VALGRIND_STRING}" == "" ]; then
      if [ "${STRING}" != "???" ]; then
        BACKUP_VALGRIND_STRING=${STRING}
      fi
    fi
    check_string
    if [ ${FLAG_GOOD} -eq 1 ]; then
      VALGRIND_STRING=${STRING}
      break
    fi
  done
fi

# In case all 11 (1+10) attempts to get a frame failed, use the backup string (which is likely too generic, but may still help to reduce the testcase correctly)
if [ "${VALGRIND_STRING}" == "" ]; then
  VALGRIND_STRING=${BACKUP_VALGRIND_STRING}
fi

echo ${VALGRIND_STRING}
