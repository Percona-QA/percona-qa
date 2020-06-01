# Created by Roel Van de Paar, MariaDB

REGEX_ECLUDE="$(cat REGEX_EXCLUDE 2>/dev/null)"  # Handy to exclude a particular build

if [ "${1}" == "ASAN" ]; then
  ls --color=never -d ASAN_M* 2>/dev/null | grep -vE "${REGEX_ECLUDE}" | grep -v tar 
else
  ls --color=never -d MD*10.[1-6]* 2>/dev/null | grep -vE "${REGEX_ECLUDE}" | grep -v tar | grep -vE "ASAN|GAL"
  ls --color=never -d MS*[58].[5670]* 2>/dev/null | grep -vE "${REGEX_ECLUDE}" | grep -v tar | grep -vE "ASAN|GAL"
  if [ "${1}" == "ALL" ]; then
    ls --color=never -d ASAN_M* 2>/dev/null | grep -vE "${REGEX_ECLUDE}" | grep -v tar 
    ls --color=never -d GAL_M* 2>/dev/null | grep -vE "${REGEX_ECLUDE}" | grep -v tar 
  fi
fi
