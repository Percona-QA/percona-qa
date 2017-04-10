#!/usr/bin/env bash

PRODUCT=""
VERSION=""
BUILD_TYPE=""
BUILD_ARCH=""

if [[ "$1" = "nginx" ]]; then
  PRODUCT="nginx"
elif [[ "$1" = "ps" || "$1" = "pxc" || "$1" = "pxb" || "$1" = "psmdb" || "$1" = "pmm-client" || "$1" = "pt" ]]; then
  PRODUCT="$1"
  VERSION="$2"
  BUILD_TYPE="$3"
  BUILD_ARCH="$4"
else
  echo "Wrong argument specified!"
  echo "Usage:"
  echo "get_download_link.sh PRODUCT VERSION BUILD_TYPE BUILD_ARCH"
  echo "PRODUCT = ps|pxc|pxb|psmdb|pt|pmm-client"
  echo "VERSION = depending on the product but eg. 5.5|5.6|5.7"
  echo "BUILD_TYPE = prod|test"
  echo "BUILD_ARCH = x86_64|i686"
  echo "If you don't specify some part the default will be used: highest version, production and x86_64."
  echo "Example: get_download_link.sh ps 5.6 prod x86_64"
  echo "Example: get_download_link.sh nginx - list redirects for nginx config"
  exit 1
fi

get_link(){
  local OPT=""
  local OPT2=""
  LINK=""
  BUILD_TYPE="${BUILD_TYPE:-prod}"
  BUILD_ARCH="${BUILD_ARCH:-x86_64}"
  if [[ -z "${VERSION}" ]] && [[ "${PRODUCT}" = "ps" || "${PRODUCT}" = "pxc" ]]; then VERSION="5.7"; fi
  if [[ -z "${VERSION}" && "${PRODUCT}" = "psmdb" ]]; then VERSION="3.4"; fi

  if [[ "${BUILD_TYPE}" = "prod" ]]; then
    if [[ "${PRODUCT}" = "ps" ]]; then
      if [[ "${VERSION}" = "5.5" || "${VERSION}" = "5.6" ]]; then
        OPT="rel[0-9]+."
      fi
      LINK=$(curl -s https://www.percona.com/downloads/Percona-Server-${VERSION}/LATEST/binary/|grep -oE "Percona-Server-${VERSION}\.[0-9]+-${OPT}[0-9]+-Linux\.${BUILD_ARCH}\.ssl100\.tar\.gz"|head -n1)
      if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/Percona-Server-${VERSION}/LATEST/binary/tarball/${LINK}"; fi
    elif [[ "${PRODUCT}" = "pxc" ]]; then
      DL_VERSION="${VERSION//./}"
      if [[ "${VERSION}" = "5.5" || "${VERSION}" = "5.6" ]]; then
        OPT="\.[0-9]+"
      fi
      if [[ "${VERSION}" != "5.5" ]]; then OPT2="\.ssl100"; fi
      LINK=$(curl -s https://www.percona.com/downloads/Percona-XtraDB-Cluster-${DL_VERSION}/LATEST/binary/|grep -oE "Percona-XtraDB-Cluster-${VERSION}\.[0-9]+-rel[0-9]+${OPT}-[0-9]+\.[0-9]+\.[0-9]+\.Linux\.${BUILD_ARCH}${OPT2}\.tar\.gz"|head -n1)
      if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/Percona-XtraDB-Cluster-${DL_VERSION}/LATEST/binary/tarball/${LINK}"; fi
    elif [[ "${PRODUCT}" = "psmdb" && "${BUILD_ARCH}" = "x86_64" ]]; then
        LINK=$(curl -s https://www.percona.com/downloads/percona-server-mongodb-${VERSION}/LATEST/binary/|grep -oE "percona-server-mongodb-${VERSION}\.[0-9]+-[0-9]+\.[0-9]+-trusty-${BUILD_ARCH}\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/percona-server-mongodb-${VERSION}/LATEST/binary/tarball/${LINK}"; fi
    elif [[ "${PRODUCT}" = "pxb" ]]; then
      LINK=$(curl -s https://www.percona.com/downloads/XtraBackup/LATEST/binary/|grep -oE "percona-xtrabackup-[0-9]+\.[0-9]+\.[0-9]+-Linux-${BUILD_ARCH}\.tar\.gz"|head -n1)
      if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/XtraBackup/LATEST/binary/tarball/${LINK}"; fi
    elif [[ "${PRODUCT}" = "pmm-client" && "${BUILD_ARCH}" = "x86_64" ]]; then
      LINK=$(curl -s https://www.percona.com/downloads/pmm-client/LATEST/binary/|grep -oE "pmm-client-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz"|head -n1)
      if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/pmm-client/LATEST/binary/tarball/${LINK}"; fi
    elif [[ "${PRODUCT}" = "pt" ]]; then
      LINK=$(curl -s https://www.percona.com/downloads/percona-toolkit/LATEST/binary/|grep -oE "percona-toolkit-[0-9]+\.[0-9]+\.[0-9]+_${BUILD_ARCH}\.tar\.gz"|head -n1)
      if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/percona-toolkit/LATEST/binary/tarball/${LINK}"; fi
    fi
  fi
}

if [[ "${PRODUCT}" = "nginx" ]]; then
  for PRODUCT in ps pxc pxb psmdb pmm-client pt; do
    for BUILD_TYPE in prod test; do
      for BUILD_ARCH in i686 x86_64; do
        if [[ "${PRODUCT}" = "ps" || "${PRODUCT}" = "pxc" ]]; then
          VERSION_ARR="5.5 5.6 5.7"
        elif [[ "${PRODUCT}" = "psmdb" ]]; then
          VERSION_ARR="3.2 3.4"
        elif [[ "${PRODUCT}" = "pt" ]]; then
          VERSION_ARR="3.0"
        elif [[ "${PRODUCT}" = "pmm-client" ]]; then
          VERSION_ARR="1.1"
        elif [[ "${PRODUCT}" = "pxb" ]]; then
          VERSION_ARR="2.4"
        fi
        for VERSION in ${VERSION_ARR}; do
          get_link
          if [[ ! -z "${LINK}" ]]; then echo "location /${PRODUCT}/${VERSION}/${BUILD_TYPE}/${BUILD_ARCH} { rewrite ^(.*)$ ${LINK} redirect; }"; fi
        done
      done
    done
  done
else
  get_link
  echo "${LINK}"
fi
