#!/bin/bash

# Download the latest version of a single file from a launchpad project.
# Created by David Bennett, Percona LLC - 2015-06-02

# NOTE: if you which to embed this code in another script or Jenkins build
# job, you can just cut and paste the code at the bottom after --EMBEDDABLE--

# Make sure we have a URL
if [ -z "$2" ]; then
  echo "Download the latest version of a single file from a launchpad project."
  echo "Usage: $0 [lp:project] [path/file.ext] {destination path}"
  exit 1
fi

# parameters

LP_PROJECT=${1#lp:}
SRC_FILE=$2
DEST_PATH=$3

# determine package manager for requirements function
pkgmgr=
hash apt-get >/dev/null 2>&1
if [ $? -eq 0 ]; then
  pkgmgr='apt-get'
else
  hash yum >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    pkgmgr='yum'
  fi
fi

# function to check for script dependency
reqmissing=0
requires()
{
  hash "$1" >/dev/null 2>&1
  if [ $? -eq 1 ]; then
    reqmissing=$((reqmissing+1))
    echo "This script requires the $1 command."
    if [ -n "${pkgmgr}" ]; then
      echo "Use the ${pkgmgr} command to install it:"
      printf "\tsudo %s install %s" ${pkgmgr} "$1"
    fi
    echo ""
  fi
}

# Make sure we have 'wget'

requires "wget"
# exit if something is missing
if [ $reqmissing -gt 0 ]; then
  exit 1
fi

# --EMBEDDABLE--
# this is the actual download, if you know the target
# system has wget, you can just set LP_PROJECT and SRC_FILE
# (and optionally DEST_PATH} here and cut & paste this block
# into your script

#LP_PROJECT=percona-qa
#SRC_FILE=download_launchpad_single_file.sh
#DEST_PATH=.

# set destination path
_DEST_PATH="${DEST_PATH:-.}"
_DEST_PATH="${_DEST_PATH%/}/"
# get the project path prefix
PROJ_PATH=$(
  wget -q -O - "http://code.launchpad.net/${LP_PROJECT}/" \
    | grep -E "href.*lp:${LP_PROJECT}" \
    | head -n1 \
    | cut -d'"' -f2
)
# validate project path
# shellcheck disable=SC2086
if [ "${PROJ_PATH}" == "" -o ${PIPESTATUS[0]} -gt 0 ]; then
  echo "ERROR: Project ${1} not found."
  exit 1
fi
# get file url
REL_URL=$(
  wget -q -O - "http://bazaar.launchpad.net${PROJ_PATH}/view/head:/${SRC_FILE}" \
    | grep 'download file' \
    | head -n1 \
    | cut -d'"' -f2
)
# validate file url
# shellcheck disable=SC2086
if [ "${REL_URL}" == "" -o ${PIPESTATUS[0]} -gt 0 ]; then
  echo "ERROR: File ${2} in project ${1} not found."
  exit 1
fi
# download
ABS_URL="http://bazaar.launchpad.net${REL_URL}"
wget -q -O - "$ABS_URL" > "${_DEST_PATH}${SRC_FILE}"

