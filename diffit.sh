#!/bin/bash
# Created by Roel Van de Paar, Percona LLC
# Updated by Tomislav Plavcic, Percona LLC

# Is to be used for pquery query correctness testing.
# This script has two modes, default mode checks query output finds first difference and outputs sql which produced that difference.
# The alternative mode produces diff between two sql files only on statements that didn't fail and outputs first diff found.

# First parameter specifies mode, default or 2
# Second parameter can specify to use vimdiff instead of diff if mode is 2
if [ "$1" == "2" ]; then
  FIRSTFILE="$(ls pquery_thread*.sql | head -n1).NOERROR"
  SECONDFILE="$(ls pquery_thread*.sql | tail -n1).NOERROR"
  grep -v "#ERROR" ${FIRSTFILE%.NOERROR} > ${FIRSTFILE}
  grep -v "#ERROR" ${SECONDFILE%.NOERROR} > ${SECONDFILE}
  if [ "$2" == "vim" ]; then
    vimdiff ${FIRSTFILE} ${SECONDFILE}
  else
    diff -W $(tput cols) --side-by-side --suppress-common-lines ${FIRSTFILE} ${SECONDFILE}
  fi
else
  FIRSTDIFFLINE=$(diff --unchanged-line-format="" *.out|head -n1|grep -oP "#[0-9]*$")
  if [ "${FIRSTDIFFLINE}" == "" ]; then echo "No differences found between files $(ls *.out | tr '\n' ' ' | sed 's| | and |')!"; exit 1; fi
  grep "${FIRSTDIFFLINE}$" *.sql
fi
