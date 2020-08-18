#!/bin/bash

if [ -z "${1}" -o -z "${2}" ]; then
  echo 'This script expects two parameters: the SQL input file, and the number of repeats:'
  echo 'repeatme input.sql 500'
  exit 1
fi
if [ ! -r "${1}" ]; then
  echo "This script tried to read '${1}' passed as the input SQL file, yet was unable to read it"
  exit 1
fi

RANDOM=$(date +%s%N | cut -b10-19)  # Random entropy init
OUT="/tmp/out.${RANDOM}"

rm -f "${OUT}"
if [ -r "${OUT}" ]; then
  echo "This script tried to delete ${OUT}, but the file still exists"
  exit 1
fi

touch ${OUT}
for seq in $(seq 1 ${2}); do
  echo 'DROP DATABASE test;CREATE DATABASE test;USE test;' >> ${OUT}
  cat ${1} >> ${OUT}
done

mv ${OUT} ${1}_rpt

echo "Done! Output file: ${1}_rpt"
