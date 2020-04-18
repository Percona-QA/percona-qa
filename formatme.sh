#!/bin/bash
# Created by Roel Van de Paar, MariaDB

if [ -z "$(whereis shfmt | awk '{print $2}')" ]; then
  sudo snap install shfmt
fi

if [ -z "${1}" ]; then
  echo "Error: please indicate which script you would like to format, as the first option to this script!"
  exit 1
fi

if [ ! -r .editorconfig ]; then
  echo "Assert: .editorconfig missing!"
  exit 1
fi

shfmt "${1}" > "${1}.tmp"  # Will use .editorconfig for formatting
echo "Produced ${1}.tmp based on ${1}"
echo "Please check the contents, then do:"
echo "mv ${1}.tmp ${1}"
echo "When you are satisfied the newly aligned code looks well."
