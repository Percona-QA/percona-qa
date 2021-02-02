#!/bin/bash
#Created by Roel Van de Paar, MariaDB
set +H

# ${1}: First input, only option, point to mysqld error log or to basedir which contains ./log/master.err

help_info(){
  echo "Usage:"
  echo "1] If you want to point the script to a specific error log in a specific location, do:"
  echo "     ~/mariadb-qa/san_text_string.sh your_error_log_location"
  echo "   Where your_error_log_location points to such a specific error log in a specific location."
  echo "2] If you want to point the script to a base directory which already contains ./log/master.err, do:"
  echo "     ~/mariadb-qa/san_text_string.sh your_base_directory"
  echo "   Where your_base_directory is a base directory which already contains ./log/master.err"
  echo "3] If you are within a base directory which already contains a ./log/master.err, do:"
  echo "     ~/mariadb-qa/san_text_string.sh"
  echo "   Without any options, as this will automatically use \${PWD}/log/master.err"
}

# Variable and error log dir/file checking
ERROR_LOG=
if [ -z "${1}" ]; then
  ERROR_LOG="$(echo "${PWD}/log/master.err")"
  if [ ! -r "${ERROR_LOG}" ]; then
    ERROR_LOG2="$(echo "${PWD}/master.err")"
    if [ ! -r "${ERROR_LOG2}" ]; then
      echo "Assert: no option passed, and ${ERROR_LOG} and ${ERROR_LOG2} do not exist."
      help_info
      exit 1
    else
      ERROR_LOG="${ERROR_LOG2}"
      ERROR_LOG2=
    fi
  fi
fi
if [ -z "${ERROR_LOG}" ]; then
  if [ -d "${1}" ]; then  # Directory passed, check normal error log location
    ERROR_LOG="$(echo "${1}/log/master.err" | sed 's|//|/|g')"
    if [ ! -r "${ERROR_LOG}" ]; then
      echo "Assert: a directory was passed to this script, and ${ERROR_LOG} does not exist within it."
      help_info
      exit 1
    fi
  fi
  if [ -r "${1}" ]; then
    ERROR_LOG="${1}"
  else
    echo "Assert: ${1} does not exist."
    help_info
    exit 1
  fi
fi
if [ -z "${ERROR_LOG}" -o ! -r "${ERROR_LOG}" ]; then
  echo "Assert: this should not happen. '${ERROR_LOG}' empty or not readable. Please debug script and/or option passed."
  exit 1
fi

# Error log verification
ERROR_LOG_LINES="$(cat "${ERROR_LOG}" 2>/dev/null | wc -l)"  # cat provides streamlined 0-reporting
if [ -z "${ERROR_LOG_LINES}" ]; then
  echo "Assert: an attempt to count the number of lines in ${ERROR_LOG} has yielded and empty result."
  exit 1
fi
if [ "${ERROR_LOG_LINES}" -eq 0 ]; then
  echo "Assert: the error log at ${ERROR_LOG} contains 0 lines."
  exit 1
elif [ "${ERROR_LOG_LINES}" -lt 10 ]; then
  echo "Assert: the error log at ${ERROR_LOG} contains less then 10 lines."
  exit 1
fi

# Error log scanning & parsing
FLAG_ASAN_IN_PROGRESS=0
FLAG_TSAN_IN_PROGRESS=0
FLAG_UBSAN_IN_PROGRESS=0
while IFS=$'\n' read LINE; do
  #echo "$LINE"
  if [[ "${LINE}" == "=ERROR:" ]]; then  # ASAN Issue detected, and commencing
    FLAG_ASAN_IN_PROGRESS=1
    
  fi

  if [[ "${LINE}" == "ThreadSanitizer:" ]]; then  # TSAN Issue detected, and commencing
    FLAG_TSAN_IN_PROGRESS=1
    
  fi

  if [[ "${LINE}" == "runtime error:" ]]; then  # UBSAN Issue detected, and commencing
    FLAG_UBSAN_IN_PROGRESS=1
    
  fi

done < "${ERROR_LOG}"


