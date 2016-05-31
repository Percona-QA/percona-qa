#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

if [ "${STY}" == "" ]; then
  echo "NO"
else
  echo "YES: ${STY}"
fi
