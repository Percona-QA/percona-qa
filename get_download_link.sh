#!/usr/bin/env bash

PRODUCT=""
VERSION=""
BUILD_TYPE="prod"
BUILD_ARCH="x86_64"
DISTRIBUTION="ubuntu"
LINK=""

usage(){
  echo -e "\nThis script can print download link for several products."
  echo -e "Usage:"
  echo -e "  get_download_link.sh --product=PRODUCT --version=VERSION --type=TYPE --arch=BUILD_ARCH  --distribution=DISTRIBUTION"
  echo -e "  or"
  echo -e "  get_download_link.sh -pPRODUCT -vVERSION -tTYPE -aARCH -dDISTRIBUTION\n"
  echo -e "PRODUCT is a mandatory parameter."
  echo -e "Available values:"
  echo -e "PRODUCT = ps|pxc|pxb|psmdb|pt|pmm-client|mysql|mariadb"
  echo -e "VERSION = depending on the product but eg. 5.5|5.6|5.7 (default: latest major version)"
  echo -e "TYPE = prod|test (default: prod)"
  echo -e "ARCH = x86_64|i686 (default: x86_64)"
  echo -e "DISTRIBUTION = ubuntu|centos (default: ubuntu)\n"
  echo -e "Example: get_download_link.sh --product=ps --version=5.6 --type=prod --arch=x86_64"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=p::v::t:a:d:h \
  --longoptions=product::,version::,type:,arch:,distribution:,help \
  --name="$(basename "$0")" -- "$@")"
  test $? -eq 0 || exit 1
  eval set -- $go_out
fi

for arg
do
  case "$arg" in
    -- ) shift; break;;
    -p | --product )
    PRODUCT="$2"
    shift 2
    ;;
    -v | --version )
    VERSION="$2"
    shift 2
    ;;
    -t | --type )
    BUILD_TYPE="$2"
    shift 2
    ;;
    -a | --arch )
    BUILD_ARCH="$2"
    shift 2
    ;;
    -d | --distribution )
    DISTRIBUTION="$2"
    shift 2
    ;;
    -h | --help )
    usage
    exit 0
    ;;
  esac
done

if [[ -z ${PRODUCT} ]]; then
  echo "ERROR: Product parameter is mandatory!"
  usage
  exit 1
fi

if [[ -z "$(which wget)" ]]; then
  echo "ERROR: wget is required for proper functioning of this script!"
  exit 1
fi

if [[ -z "${VERSION}" ]] && [[ "${PRODUCT}" = "ps" || "${PRODUCT}" = "pxc" || "${PRODUCT}" = "mysql" ]]; then VERSION="5.7"; fi
if [[ -z "${VERSION}" ]] && [[ "${PRODUCT}" = "mariadb" ]]; then VERSION="10.1"; fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "psmdb" ]]; then VERSION="3.4"; fi

get_link(){
  local OPT=""
  local OPT2=""
  if [[ "${DISTRIBUTION}" = "ubuntu" ]]; then
    SSL_VER="ssl100"
  else
    SSL_VER="ssl101"
  fi
  if [[ "${BUILD_TYPE}" = "prod" ]]; then
    if [[ "${PRODUCT}" = "ps" ]]; then
      if [[ "${VERSION}" = "5.5" || "${VERSION}" = "5.6" ]]; then
        OPT="rel[0-9]+."
      fi
      LINK=$(wget -qO- https://www.percona.com/downloads/Percona-Server-${VERSION}/LATEST/binary/|grep -oE "Percona-Server-${VERSION}\.[0-9]+-${OPT}[0-9]+-Linux\.${BUILD_ARCH}\.${SSL_VER}\.tar\.gz"|head -n1)
      if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/Percona-Server-${VERSION}/LATEST/binary/tarball/${LINK}"; fi
    elif [[ "${PRODUCT}" = "pxc" ]]; then
      DL_VERSION="${VERSION//./}"
      if [[ "${VERSION}" = "5.5" || "${VERSION}" = "5.6" ]]; then
        OPT="\.[0-9]+"
      fi
      if [[ "${VERSION}" != "5.5" ]]; then OPT2="\.${SSL_VER}"; fi
      LINK=$(wget -qO- https://www.percona.com/downloads/Percona-XtraDB-Cluster-${DL_VERSION}/LATEST/binary/|grep -oE "Percona-XtraDB-Cluster-${VERSION}\.[0-9]+-rel[0-9]+${OPT}-[0-9]+\.[0-9]+\.[0-9]+\.Linux\.${BUILD_ARCH}${OPT2}\.tar\.gz"|head -n1)
      if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/Percona-XtraDB-Cluster-${DL_VERSION}/LATEST/binary/tarball/${LINK}"; fi
    elif [[ "${PRODUCT}" = "psmdb" && "${BUILD_ARCH}" = "x86_64" ]]; then
      if [[ "${DISTRIBUTION}" = "ubuntu" ]]; then OPT="xenial"; else OPT="centos6"; fi
      LINK=$(wget -qO- https://www.percona.com/downloads/percona-server-mongodb-${VERSION}/LATEST/binary/|grep -oE "percona-server-mongodb-${VERSION}\.[0-9]+-[0-9]+\.[0-9]+-trusty-${BUILD_ARCH}\.tar\.gz"|head -n1)
      if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/percona-server-mongodb-${VERSION}/LATEST/binary/tarball/${LINK}"; fi
    elif [[ "${PRODUCT}" = "pxb" ]]; then
      LINK=$(wget -qO- https://www.percona.com/downloads/XtraBackup/LATEST/binary/|grep -oE "percona-xtrabackup-[0-9]+\.[0-9]+\.[0-9]+-Linux-${BUILD_ARCH}\.tar\.gz"|head -n1)
      if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/XtraBackup/LATEST/binary/tarball/${LINK}"; fi
    elif [[ "${PRODUCT}" = "pmm-client" && "${BUILD_ARCH}" = "x86_64" ]]; then
      LINK=$(wget -qO- https://www.percona.com/downloads/pmm-client/LATEST/binary/|grep -oE "pmm-client-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz"|head -n1)
      if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/pmm-client/LATEST/binary/tarball/${LINK}"; fi
    elif [[ "${PRODUCT}" = "pt" ]]; then
      LINK=$(wget -qO- https://www.percona.com/downloads/percona-toolkit/LATEST/binary/|grep -oE "percona-toolkit-[0-9]+\.[0-9]+\.[0-9]+_${BUILD_ARCH}\.tar\.gz"|head -n1)
      if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/percona-toolkit/LATEST/binary/tarball/${LINK}"; fi
    elif [[ "${PRODUCT}" = "mysql" ]]; then
      BASE_LINK="https://dev.mysql.com/get/Downloads/MySQL-${VERSION}/"
      TARBALL=$(wget -qO- https://dev.mysql.com/downloads/mysql/${VERSION}.html\?os\=2|grep -o -P "(mysql|MySQL).*${BUILD_ARCH}.tar.gz"|grep -v "mysql-test"|head -n1)
      LINK="${BASE_LINK}${TARBALL}"
    elif [[ "${PRODUCT}" = "mariadb" ]]; then
      if [[ ${BUILD_ARCH} = "x86_64" ]]; then
        BUILD_ARCH_TMP="${BUILD_ARCH}"
      else
        BUILD_ARCH_TMP="x86"
      fi
      # main alternative which doesn't provide directory listing
      # https://downloads.mariadb.org/f/mariadb-10.1.23/bintar-linux-x86_64/mariadb-10.1.23-linux-x86_64.tar.gz
      BASE_LINK="http://ftp.nluug.nl/db/mariadb/"
      DIRECTORY=$(wget -qO- http://ftp.nluug.nl/db/mariadb/|grep -o "mariadb-${VERSION}.[0-9]*"|tail -n1)
      if [[ -z ${DIRECTORY} ]]; then
        LINK=""
      else
        VERSION_FULL="${DIRECTORY#mariadb-}"
        DIRECTORY="${DIRECTORY}/bintar-linux-${BUILD_ARCH_TMP}/"
        TARBALL="mariadb-${VERSION_FULL}-linux-${BUILD_ARCH}.tar.gz"
        LINK="${BASE_LINK}${DIRECTORY}${TARBALL}"
      fi
    fi
  fi
}

get_link
if [[ -z ${LINK} ]]; then
  exit 1
else
  if wget --spider ${LINK} 2>/dev/null; then
    echo "${LINK}"
    exit 0
  else
    exit 1
  fi
fi
