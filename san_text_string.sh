#!/bin/bash
#Created by Roel Van de Paar, MariaDB
set +H

# ${1}: First input, only option, point to mysqld error log or to basedir which contains ./log/master.err

help_info(){
  echo "Usage:"
  echo "1] If you want to point the script to a specific error log in a specific location, do:"
  echo "   ~/mariadb-qa/san_text_string.sh your_error_log_location"
  echo "   Where your_error_log_location points to such a specific error log in a specific location."
  echo "2] If you want to point the script to a base directory which already contains ./log/master.err, do:"
  echo "   ~/mariadb-qa/san_text_string.sh your_base_directory"
  echo "   Where your_base_directory is a base directory which already contains ./log/master.err"
  echo "3] If you are within a base directory which already contains a ./log/master.err, do:"
  echo "   ~/mariadb-qa/san_text_string.sh"
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

flag_ready_check(){
  if [ "${FLAG_ASAN_IN_PROGRESS}"  -eq 1 ]; then FLAG_ASAN_READY=1;  else FLAG_ASAN_READY=0;  fi
  if [ "${FLAG_TSAN_IN_PROGRESS}"  -eq 1 ]; then FLAG_TSAN_READY=1;  else FLAG_TSAN_READY=0;  fi
  if [ "${FLAG_UBSAN_IN_PROGRESS}" -eq 1 ]; then FLAG_UBSAN_READY=1; else FLAG_UBSAN_READY=0; fi
  # Check imposibilties
  if [ "${FLAG_ASAN_READY}" -eq 1 -a "${FLAG_TSAN_READY}" -eq 1 ]; then
    echo "Assert: FLAG_ASAN_READY=1, FLAG_TSAN_READY=1"
    exit 1
  fi
  if [ "${FLAG_TSAN_READY}" -eq 1 -a "${FLAG_UBSAN_READY}" -eq 1 ]; then
    echo "Assert: FLAG_TSAN_READY=1, FLAG_UBSAN_READY=1"
    exit 1
  fi
  if [ "${FLAG_ASAN_READY}" -eq 1 -a "${FLAG_UBSAN_READY}" -eq 1 ]; then
    echo "Assert: FLAG_ASAN_READY=1, FLAG_UBSAN_READY=1"
    exit 1
  fi
}

# Error log scanning & parsing
FLAG_ASAN_IN_PROGRESS=0; FLAG_TSAN_IN_PROGRESS=0; FLAG_UBSAN_IN_PROGRESS=0
FLAG_ASAN_READY=0; FLAG_TSAN_READY=0; FLAG_UBSAN_READY=0
LINE_COUNTER=0
while IFS=$'\n' read LINE; do
  LINE_COUNTER=$[ ${LINE_COUNTER} + 1 ]
  # Prevent current or future issues with tabs. Note: do not modify the next line as space based parsing exists below
  LINE="$(echo "${LINE}" | sed 's|\t| |g')"
  if [[ "${LINE}" == *"=ERROR:"* ]]; then  # ASAN Issue detected, and commencing
    flag_ready_check
    FLAG_ASAN_IN_PROGRESS=1; FLAG_TSAN_IN_PROGRESS=0; FLAG_UBSAN_IN_PROGRESS=0
    
    
  fi

  if [[ "${LINE}" == *"ThreadSanitizer:"* ]]; then  # TSAN Issue detected, and commencing
    flag_ready_check
    FLAG_ASAN_IN_PROGRESS=0; FLAG_TSAN_IN_PROGRESS=1; FLAG_UBSAN_IN_PROGRESS=0

    
  fi

  if [[ "${LINE}" == *"runtime error:"* ]]; then  # UBSAN Issue detected, and commencing
    flag_ready_check
    FLAG_ASAN_IN_PROGRESS=0; FLAG_TSAN_IN_PROGRESS=0; FLAG_UBSAN_IN_PROGRESS=1
    UBSAN_FRAME1=; UBSAN_FRAME2=; UBSAN_FRAME3=; UBSAN_FRAME4=
    UBSAN_ERROR="$(echo "${LINE}" | sed 's|.*runtime error:|runtime error:|')"
    UBSAN_FILE_PREPARSE="$(echo "${LINE}" | sed 's| runtime error:.*||;s|:[0-9]\+:[0-9]\+:[ ]*$||')" 
    UBSAN_FILE_PREPARSE="$(echo "${UBSAN_FILE_PREPARSE}" | sed 's|.*/client/|client/|;s|.*/cmake/|cmake/|;s|.*/dbug/|dbug/|;s|.*/debian/|debian/|;s|.*/extra/|extra/|;s|.*/include/|include/|;s|.*/libmariadb/|libmariadb/|;s|.*/libmysqld/|libmysqld/|;s|.*/libservices/|libservices/|;s|.*/mysql-test/|mysql-test/|;s|.*/mysys/|mysys/|;s|.*/mysys_ssl/|mysys_ssl/|;s|.*/plugin/|plugin/|;s|.*/scripts/|scripts/|;s|.*/sql/|sql/|;s|.*/sql-bench/|sql-bench/|;s|.*/sql-common/|sql-common/|;s|.*/storage/|storage/|;s|.*/strings/|strings/|;s|.*/support-files/|support-files/|;s|.*/tests/|tests/|;s|.*/tpool/|tpool/|;s|.*/unittest/|unittest/|;s|.*/vio/|vio/|;s|.*/win/|win/|;s|.*/wsrep-lib/|wsrep-lib/|;s|.*/zlib/|zlib/|;s|.*/components/|components/|;s|.*/libbinlogevents/|libbinlogevents/|;s|.*/libbinlogstandalone/|libbinlogstandalone/|;s|.*/libmysql/|libmysql/|;s|.*/router/|router/|;s|.*/share/|share/|;s|.*/testclients/|testclients/|;s|.*/utilities/|utilities/|;s|.*/regex/|regex/|;')"  # Drop path prefix (build directory), leaving only relevant part for MD/MS
    
  fi
  if [ "${FLAG_UBSAN_IN_PROGRESS}" -eq 1 ]; then
    # Parse first 4 stack frames if discovered in current line
    if [[ "${LINE}" == *" #0 0x"* ]]; then
      UBSAN_FRAME1="$(echo "${LINE}" | sed 's|^[^i]\+in[ ]\+||;s|[ ]\+.*||;s|(.*)[ ]*$||')"
    fi
    if [[ "${LINE}" == *" #1 0x"* ]]; then
      UBSAN_FRAME2="$(echo "${LINE}" | sed 's|^[^i]\+in[ ]\+||;s|[ ]\+.*||;s|(.*)[ ]*$||')"
    fi
    if [[ "${LINE}" == *" #2 0x"* ]]; then
      UBSAN_FRAME3="$(echo "${LINE}" | sed 's|^[^i]\+in[ ]\+||;s|[ ]\+.*||;s|(.*)[ ]*$||')"
    fi
    if [[ "${LINE}" == *" #3 0x"* ]]; then
      UBSAN_FRAME4="$(echo "${LINE}" | sed 's|^[^i]\+in[ ]\+||;s|[ ]\+.*||;s|(.*)[ ]*$||')"
      FLAG_UBSAN_IN_PROGRESS=0  # UBSAN issues are herewith fully defined
      FLAG_UBSAN_READY=1
    fi
     
      
  fi
  if [ ${LINE_COUNTER} -eq ${ERROR_LOG_LINES} ]; then  # End of file reached, check for any final in-progress issues
    flag_ready_check
  fi
  if [ "${FLAG_UBSAN_READY}" -eq 1 ]; then
    FLAG_UBSAN_STRING_COMMENCED=0
    UNIQUE_ID=
    if [ ! -z "${UBSAN_FILE_PREPARSE}" ]; then 
      UNIQUE_ID="${UBSAN_FILE_PREPARSE}"
      FLAG_UBSAN_STRING_COMMENCED=1
    fi
    if [ ! -z "${UBSAN_ERROR}" ]; then
      if [ "${FLAG_UBSAN_STRING_COMMENCED}" -eq 1 ]; then
        UNIQUE_ID="${UNIQUE_ID}|${UBSAN_ERROR}"
      else
        UNIQUE_ID="${UBSAN_ERROR}"
        FLAG_UBSAN_STRING_COMMENCED=1
      fi
    fi
    if [ ! -z "${UBSAN_FRAME1}" ]; then 
      if [ "${FLAG_UBSAN_STRING_COMMENCED}" -eq 1 ]; then
        UNIQUE_ID="${UNIQUE_ID}|${UBSAN_FRAME1}"
      else
        UNIQUE_ID="${UBSAN_FRAME1}"
        FLAG_UBSAN_STRING_COMMENCED=1
      fi
    else 
      if [ -z "${UNIQUE_ID}" ]; then
        echo "Assert: UBSAN UNIQUE_ID generation issue"
        exit 1
      fi
    fi
    if [ ! -z "${UBSAN_FRAME2}" ]; then
      UNIQUE_ID="${UNIQUE_ID}|${UBSAN_FRAME2}" 
    fi
    if [ ! -z "${UBSAN_FRAME3}" ]; then
      UNIQUE_ID="${UNIQUE_ID}|${UBSAN_FRAME3}" 
    fi
    if [ ! -z "${UBSAN_FRAME4}" ]; then
      UNIQUE_ID="${UNIQUE_ID}|${UBSAN_FRAME4}" 
    fi
    echo "${UNIQUE_ID}"
    FLAG_UBSAN_READY=0
    FLAG_UBSAN_STRING_COMMENCED=0
    UNIQUE_ID=
  fi
done < "${ERROR_LOG}"


