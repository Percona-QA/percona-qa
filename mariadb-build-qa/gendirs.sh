#!/bin/bash
# Created by Roel Van de Paar, MariaDB

ls -d MD*10.[1-6]* 2>/dev/null | grep -v tar | grep -vE "ASAN|GAL"
ls -d MS*[58].[5670]* 2>/dev/null | grep -v tar | grep -vE "ASAN|GAL"

if [ "${1}" == "ALL" ]; then
  ls -d ASAN_M* 2>/dev/null | grep -v tar 
  ls -d GAL_M* 2>/dev/null | grep -v tar 
fi
