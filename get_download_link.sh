#!/usr/bin/env bash

PRODUCT=""
VERSION=""
BUILD_TYPE="prod"
BUILD_ARCH="x86_64"
DISTRIBUTION="ubuntu"
LINK=""
DOWNLOAD=0

usage(){
  echo -e "\nThis script prints download link for several products."
  echo -e "Usage:"
  echo -e "  get_download_link.sh --product=PRODUCT --version=VERSION --type=TYPE --arch=BUILD_ARCH --distribution=DISTRIBUTION --download"
  echo -e "  or"
  echo -e "  get_download_link.sh -pPRODUCT -vVERSION -tTYPE -aARCH -dDISTRIBUTION -g\n"
  echo -e "Valid options are:"
  echo -e "  --product=PRODUCT, -pPRODUCT   this is the only mandatory parameter"
  echo -e "                                 can be ps|pxc|pxb|psmdb|pt|pmm-client|mysql|mariadb|proxysql"
  echo -e "  --version=x.x, -vx.x           major or full version of the product like 5.7 or 5.7.17-12"
  echo -e "                                 (default: latest major version)"
  echo -e "  --type=TYPE, -tTYPE            build type, can be prod|test (default: prod)"
  echo -e "  --arch=ARCH, -aARCH            build architecture, can be x86_64|i686 (default: x86_64)"
  echo -e "  --distribution=DIST, -dDIST    needed because of SSL linking, can be centos|ubuntu (default: ubuntu)"
  echo -e "  --download, -g                 download tarball with wget (default: off)\n"
  echo -e "Examples: get_download_link.sh --product=ps --version=5.6 --type=prod --arch=x86_64"
  echo -e "          get_download_link.sh --product=ps --version=5.7.17-12"
  echo -e "          get_download_link.sh --product=mysql --version=5.7.17 --download"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=p:v:t:a:d:hg \
  --longoptions=product:,version:,type:,arch:,distribution:,help,download \
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
    -g | --download )
    DOWNLOAD=1
    shift
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
if [[ -z "${VERSION}" ]] && [[ "${PRODUCT}" = "mariadb" ]]; then VERSION="10.2"; fi
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
    if [[ $(grep -o "\." <<< "${VERSION}" | wc -l) -gt 1 ]]; then
      VERSION_FULL=${VERSION}
      VERSION=$(echo "${VERSION_FULL}"|awk -F '.' '{print $1"."$2}')
    else
      VERSION_FULL=""
    fi

    if [[ "${PRODUCT}" = "ps" ]]; then
      if [[ "${VERSION}" = "5.5" || "${VERSION}" = "5.6" ]]; then
        if [[ -z ${VERSION_FULL} ]]; then
          OPT="rel[0-9]+."
        else
          OPT="rel"
        fi
      fi
      if [[ -z ${VERSION_FULL} ]]; then
        LINK=$(wget -qO- https://www.percona.com/downloads/Percona-Server-${VERSION}/LATEST/binary/|grep -oE "Percona-Server-${VERSION}\.[0-9]+-${OPT}[0-9]+-Linux\.${BUILD_ARCH}\.${SSL_VER}\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/Percona-Server-${VERSION}/LATEST/binary/tarball/${LINK}"; fi
      else
        VERSION_UPSTREAM=$(echo "${VERSION_FULL}" | awk -F '-' '{print $1}')
        VERSION_PERCONA=$(echo "${VERSION_FULL}" | awk -F '-' '{print $2}')
        LINK="https://www.percona.com/downloads/Percona-Server-${VERSION}/Percona-Server-${VERSION_FULL}/binary/tarball/Percona-Server-${VERSION_UPSTREAM}-${OPT}${VERSION_PERCONA}-Linux.${BUILD_ARCH}.${SSL_VER}.tar.gz"
      fi

    elif [[ "${PRODUCT}" = "pxc" ]]; then
      DL_VERSION="${VERSION//./}"
      if [[ "${VERSION}" = "5.5" || "${VERSION}" = "5.6" ]]; then
        OPT="\.[0-9]+"
      fi
      if [[ "${VERSION}" != "5.5" ]]; then OPT2=".${SSL_VER}"; fi
      if [[ -z ${VERSION_FULL} ]]; then
        LINK=$(wget -qO- https://www.percona.com/downloads/Percona-XtraDB-Cluster-${DL_VERSION}/LATEST/binary/|grep -oE "Percona-XtraDB-Cluster-${VERSION}\.[0-9]+-rel[0-9]+${OPT}-[0-9]+\.[0-9]+\.[0-9]+\.Linux\.${BUILD_ARCH}${OPT2}\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/Percona-XtraDB-Cluster-${DL_VERSION}/LATEST/binary/tarball/${LINK}"; fi
      else
        VERSION_UPSTREAM=$(echo "${VERSION_FULL}" | awk -F '-' '{print $1}')
        VERSION_PERCONA=$(echo "${VERSION_FULL}" | awk -F '-' '{print $2}')
        VERSION_WSREP=$(echo "${VERSION_FULL}" | awk -F '-' '{print $3}')
        VERSION_WSREP_TMP=$(echo "${VERSION_WSREP}" | sed 's/\(.*\)\./\1-/')
        if [[ "${VERSION}" = "5.7" ]]; then VERSION_WSREP_TMP="${VERSION_WSREP_TMP%-*}"; fi
        LINK="https://www.percona.com/downloads/Percona-XtraDB-Cluster-${DL_VERSION}/Percona-XtraDB-Cluster-${VERSION_UPSTREAM}-${VERSION_WSREP_TMP}/binary/tarball/Percona-XtraDB-Cluster-${VERSION_UPSTREAM}-rel${VERSION_PERCONA}-${VERSION_WSREP}.Linux.${BUILD_ARCH}${OPT2}.tar.gz"
      fi

    elif [[ "${PRODUCT}" = "psmdb" && "${BUILD_ARCH}" = "x86_64" ]]; then
      if [[ "${DISTRIBUTION}" = "ubuntu" ]]; then OPT="xenial"; else OPT="centos6"; fi
      if [[ -z ${VERSION_FULL} ]]; then
        LINK=$(wget -qO- https://www.percona.com/downloads/percona-server-mongodb-${VERSION}/LATEST/binary/|grep -oE "percona-server-mongodb-${VERSION}\.[0-9]+-[0-9]+\.[0-9]+-${OPT}-${BUILD_ARCH}\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/percona-server-mongodb-${VERSION}/LATEST/binary/tarball/${LINK}"; fi
      else
        VERSION_UPSTREAM=$(echo "${VERSION_FULL}" | awk -F '-' '{print $1}')
        VERSION_PERCONA=$(echo "${VERSION_FULL}" | awk -F '-' '{print $2}')
        LINK="https://www.percona.com/downloads/percona-server-mongodb-${VERSION}/percona-server-mongodb-${VERSION_UPSTREAM}-${VERSION_PERCONA}/binary/tarball/percona-server-mongodb-${VERSION_UPSTREAM}-${VERSION_PERCONA}-${OPT}-${BUILD_ARCH}.tar.gz"
      fi

    elif [[ "${PRODUCT}" = "pxb" ]]; then
      if [[ -z ${VERSION_FULL} ]]; then
        LINK=$(wget -qO- https://www.percona.com/downloads/XtraBackup/LATEST/binary/|grep -oE "percona-xtrabackup-[0-9]+\.[0-9]+\.[0-9]+-Linux-${BUILD_ARCH}\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/XtraBackup/LATEST/binary/tarball/${LINK}"; fi
      else
        LINK="https://www.percona.com/downloads/XtraBackup/Percona-XtraBackup-${VERSION_FULL}/binary/tarball/percona-xtrabackup-${VERSION_FULL}-Linux-${BUILD_ARCH}.tar.gz"
      fi

    elif [[ "${PRODUCT}" = "pmm-client" && "${BUILD_ARCH}" = "x86_64" ]]; then
      if [[ -z ${VERSION_FULL} ]]; then
        LINK=$(wget -qO- https://www.percona.com/downloads/pmm-client/LATEST/binary/|grep -oE "pmm-client-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/pmm-client/LATEST/binary/tarball/${LINK}"; fi
      else
        LINK="https://www.percona.com/downloads/pmm-client/pmm-client-${VERSION_FULL}/binary/tarball/pmm-client-${VERSION_FULL}.tar.gz"
      fi

    elif [[ "${PRODUCT}" = "pt" ]]; then
      if [[ -z ${VERSION_FULL} ]]; then
        LINK=$(wget -qO- https://www.percona.com/downloads/percona-toolkit/LATEST/binary/|grep -oE "percona-toolkit-[0-9]+\.[0-9]+\.[0-9]+_${BUILD_ARCH}\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/percona-toolkit/LATEST/binary/tarball/${LINK}"; fi
      else
        LINK="https://www.percona.com/downloads/percona-toolkit/${VERSION_FULL}/binary/tarball/percona-toolkit-${VERSION_FULL}_${BUILD_ARCH}.tar.gz"
      fi

    elif [[ "${PRODUCT}" = "mysql" ]]; then
      if [[ -z ${VERSION_FULL} ]]; then
        BASE_LINK="https://dev.mysql.com/get/Downloads/MySQL-${VERSION}/"
        TARBALL=$(wget -qO- https://dev.mysql.com/downloads/mysql/${VERSION}.html\?os\=2|grep -o -P "(mysql|MySQL).*${BUILD_ARCH}.tar.gz"|grep -v "mysql-test"|head -n1)
        LINK="${BASE_LINK}${TARBALL}"
      else
        LINK="https://dev.mysql.com/get/Downloads/MySQL-${VERSION}/mysql-${VERSION_FULL}-linux-glibc2.5-${BUILD_ARCH}.tar.gz"
      fi

    elif [[ "${PRODUCT}" = "mariadb" ]]; then
      if [[ ${BUILD_ARCH} = "x86_64" ]]; then
        BUILD_ARCH_TMP="${BUILD_ARCH}"
      else
        BUILD_ARCH_TMP="x86"
      fi
      # main alternative which doesn't provide directory listing
      # https://downloads.mariadb.org/f/mariadb-10.1.23/bintar-linux-x86_64/mariadb-10.1.23-linux-x86_64.tar.gz
      if [[ -z ${VERSION_FULL} ]]; then
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
      else
          LINK="https://downloads.mariadb.org/f/mariadb-${VERSION_FULL}/bintar-linux-${BUILD_ARCH_TMP}/mariadb-${VERSION_FULL}-linux-${BUILD_ARCH}.tar.gz"
      fi # version_full

    elif [[ "${PRODUCT}" = "proxysql" ]]; then
      if [[ -z ${VERSION_FULL} ]]; then
        BASE_LINK="https://www.percona.com/downloads/proxysql/"
        VERSION=$(wget -qO- ${BASE_LINK}|grep -o "proxysql-[0-9]*.[0-9]*.[0-9]*"|head -n1|sed 's/^.*-//')
        TARBALL="proxysql-${VERSION}-Linux-${BUILD_ARCH}.tar.gz"
        LINK="${BASE_LINK}proxysql-${VERSION}/binary/tarball/${TARBALL}"
      else
        LINK="https://www.percona.com/downloads/proxysql/proxysql-${VERSION_FULL}/binary/tarball/proxysql-${VERSION_FULL}-Linux-${BUILD_ARCH}.tar.gz"
      fi
    fi # last product

  fi # build type
}

get_link
if [[ -z ${LINK} ]]; then
  exit 1
else
  if wget --spider ${LINK} 2>/dev/null; then
    echo "${LINK}"
    if [[ ${DOWNLOAD} -eq 1 ]]; then
      wget ${LINK}
    else
      exit 0
    fi
  else
    exit 1
  fi
fi
