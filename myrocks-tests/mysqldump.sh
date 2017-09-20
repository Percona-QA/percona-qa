#!/bin/bash

# Created by Shahriyar Rzayev from Percona

WORKDIR="${PWD}"
DIRNAME=$(dirname "$0")

BASEDIR=$(ls -1td ${WORKDIR}/PS* | grep -v ".tar" | grep PS[0-9])

function extract_user() {
  user_conn="$(cat $1/cl_noprompt  | awk {'print $3'})"
  echo ${user_conn}
}

extract_user $BASEDIR
