#!/usr/bin/env bash
# Created by Tomislav Plavcic, Percona LLC

PRODUCT=""
VERSION=""
DIST_REL=""
LINK=""
DOWNLOAD=0
SOURCE=0

usage(){
  echo -e "\nThis script prints download link for several products."
  echo -e "Usage:"
  echo -e "  get_download_link.sh --product=PRODUCT --version=VERSION --arch=BUILD_ARCH --distribution=DISTRIBUTION --download"
  echo -e "  or"
  echo -e "  get_download_link.sh -pPRODUCT -vVERSION -aARCH -dDISTRIBUTION -g\n"
  echo -e "Valid options are:"
  echo -e "  --product=PRODUCT, -pPRODUCT   this is the only mandatory parameter"
  echo -e "                                 can be ps|pxc|pxb|psmdb|pt|pmm-client|mysql|mariadb|mongodb|proxysql|vault|postgresql"
  echo -e "  --version=x.x, -vx.x           major or full version of the product like 5.7 or 5.7.17-12"
  echo -e "                                 (default: latest major version)"
  echo -e "  --arch=ARCH, -aARCH            build architecture, can be x86_64|i686 (default: x86_64)"
  echo -e "  --distribution=DIST, -dDIST    needed because of SSL linking, can be centos|ubuntu (default: ubuntu)"
  echo -e "                                 also can be specified like ubuntu-bionic or centos-7 if build is specific"
  echo -e "  --source, -s                   get source tarball instead of binary"
  echo -e "  --download, -g                 download tarball with wget (default: off)\n"
  echo -e "Examples: get_download_link.sh --product=ps --version=5.6 --arch=x86_64"
  echo -e "          get_download_link.sh --product=ps --version=5.7.17-12"
  echo -e "          get_download_link.sh --product=mysql --version=5.7.17 --download"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=p:v:a:d:hsg \
  --longoptions=product:,version:,arch:,distribution:,help,source,download \
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
    -a | --arch )
    BUILD_ARCH="$2"
    shift 2
    ;;
    -d | --distribution )
    DISTRIBUTION="$2"
    shift 2
    ;;
    -s | --source )
    SOURCE=1
    shift
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

if [[ -z ${BUILD_ARCH} ]]; then
  BUILD_ARCH="x86_64"
fi

if [[ -z ${DISTRIBUTION} ]]; then
  DISTRIBUTION="ubuntu"
fi

if [[ -z "$(which wget)" ]]; then
  echo "ERROR: wget is required for proper functioning of this script!"
  exit 1
fi

if [[ -z "${VERSION}" ]] && [[ "${PRODUCT}" = "ps" || "${PRODUCT}" = "pxc" ]]; then VERSION="8.0"; fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "mysql" ]]; then VERSION="8.0"; fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "pxb" ]]; then VERSION="8.0"; fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "mariadb" ]]; then VERSION="10.4"; fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "psmdb" ]]; then VERSION="4.2"; fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "mongodb" ]]; then VERSION="4.2"; fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "postgresql" ]]; then
  VERSION=$(wget -qO- https://www.enterprisedb.com/download-postgresql-binaries|grep -oE "postgresql-.*-x64-.*.tar.gz"|head -n1|grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?"|head -n1)
fi

if [[ "${DISTRIBUTION}" = *"-"* ]]; then
  DIST_REL=$(echo "${DISTRIBUTION}" | cut -d- -f2)
  DISTRIBUTION=$(echo "${DISTRIBUTION}" | cut -d- -f1)
fi

get_link(){
  local OPT=""
  local OPT2=""

  if [[ "${DISTRIBUTION}" = "ubuntu" && "${DIST_REL}" = "jammy" ]]; then
    GLIBC_VERSION="glibc2.35-zenfs."
    SSL_VER=""
  else
    GLIBC_VERSION="glibc2.17."
    SSL_VER=""
  fi

  if [[ $(grep -o "\." <<< "${VERSION}" | wc -l) -gt 1 ]]; then
    VERSION_FULL=${VERSION}
    VERSION=$(echo "${VERSION_FULL}"|awk -F '.' '{print $1"."$2}')
  else
    VERSION_FULL=""
  fi

  if [[ "${PRODUCT}" = "ps" ]]; then
    if [[ "${VERSION}" = "5.6" ]]; then
      GLIBC_VERSION=""
      SSL_VER="ssl101."
      OPT="rel"
      if [[ ${SOURCE} = 1 ]]; then OPT=${OPT#rel}; fi
    fi
    if [[ -z ${VERSION_FULL} ]]; then
      if [[ ${SOURCE} = 0 ]]; then
        LINK=$(wget -qO- https://downloads.percona.com/downloads/Percona-Server-${VERSION}/LATEST/binary/|grep -oE "Percona-Server-${VERSION}\.[0-9]+-[0-9]+(\.[0-9]+)?"|head -n1)
        PS_VER_MAJ=$(echo "${LINK}" | cut -d- -f3)
        PS_VER_MIN=$(echo "${LINK}" | cut -d- -f4)
        if [[ ! -z ${LINK} ]]; then LINK="https://downloads.percona.com/downloads/Percona-Server-${VERSION}/LATEST/binary/tarball/Percona-Server-${PS_VER_MAJ}-${OPT}${PS_VER_MIN}-Linux.${BUILD_ARCH}.${SSL_VER}${GLIBC_VERSION}tar.gz"; fi
      else
        LINK=$(wget -qO- https://downloads.percona.com/downloads/Percona-Server-${VERSION}/LATEST/source/|grep -oE "percona-server-${VERSION}\.[0-9]+-${OPT}[0-9]+(\.[0-9]+)?\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://downloads.percona.com/downloads/Percona-Server-${VERSION}/LATEST/source/tarball/${LINK}"; fi
      fi
    else
      VERSION_UPSTREAM=$(echo "${VERSION_FULL}" | awk -F '-' '{print $1}')
      VERSION_PERCONA=$(echo "${VERSION_FULL}" | awk -F '-' '{print $2}')
      if [[ ${SOURCE} = 0 ]]; then
        LINK="https://downloads.percona.com/downloads/Percona-Server-${VERSION}/Percona-Server-${VERSION_FULL}/binary/tarball/Percona-Server-${VERSION_UPSTREAM}-${VERSION_PERCONA}-Linux.${BUILD_ARCH}.${SSL_VER}.tar.gz"
      else
        LINK="https://downloads.percona.com/downloads/Percona-Server-${VERSION}/Percona-Server-${VERSION_FULL}/source/tarball/percona-server-${VERSION_UPSTREAM}-${VERSION_PERCONA}.tar.gz"
      fi
    fi

  elif [[ "${PRODUCT}" = "pxc" ]]; then
    DL_VERSION="${VERSION//./}"
    if [[ "${VERSION}" == "5.7" ]]; then OPT2=".glibc2.12"; fi
    if [[ "${VERSION}" == "8.0" ]]; then OPT2=".glibc2.17"; fi
    if [[ -z ${VERSION_FULL} ]]; then
      if [[ ${SOURCE} = 0 ]]; then
        LINK=$(wget -qO- https://downloads.percona.com/downloads/Percona-XtraDB-Cluster-${DL_VERSION}/LATEST/binary/|grep -oE "Percona-XtraDB-Cluster[-_]${VERSION}\.[0-9]+(-rel[0-9]+)?${OPT}-[0-9]+\.[0-9]+(\.[0-9]+)?[\._]Linux\.${BUILD_ARCH}${OPT2}\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://downloads.percona.com/downloads/Percona-XtraDB-Cluster-${DL_VERSION}/LATEST/binary/tarball/${LINK}"; fi
      else
        LINK=$(wget -qO- https://downloads.percona.com/downloads/Percona-XtraDB-Cluster-${DL_VERSION}/LATEST/source/|grep -oE "Percona-XtraDB-Cluster-${VERSION}\.[0-9]+-[0-9]+(\.[0-9]+)?\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://downloads.percona.com/downloads/Percona-XtraDB-Cluster-${DL_VERSION}/LATEST/source/tarball/${LINK}"; fi
      fi
    else
      VERSION_UPSTREAM=$(echo "${VERSION_FULL}" | awk -F '-' '{print $1}')
      VERSION_PERCONA=$(echo "${VERSION_FULL}" | awk -F '-' '{print $2}')
      VERSION_WSREP=$(echo "${VERSION_FULL}" | awk -F '-' '{print $3}')
      VERSION_WSREP_TMP=$(echo "${VERSION_WSREP}" | sed 's/\(.*\)\./\1-/')
      if [[ "${VERSION}" = "5.7" ]]; then VERSION_WSREP_TMP="${VERSION_WSREP_TMP%-*}"; fi
      if [[ ${SOURCE} = 0 ]]; then
        LINK="https://downloads.percona.com/downloads/Percona-XtraDB-Cluster-${DL_VERSION}/Percona-XtraDB-Cluster-${VERSION_UPSTREAM}-${VERSION_WSREP}/binary/tarball/Percona-XtraDB-Cluster-${VERSION_UPSTREAM}-rel${VERSION_PERCONA}-${VERSION_WSREP}.Linux.${BUILD_ARCH}${OPT2}.tar.gz"
      else
        LINK="https://downloads.percona.com/downloads/Percona-XtraDB-Cluster-${DL_VERSION}/Percona-XtraDB-Cluster-${VERSION_UPSTREAM}-${VERSION_WSREP}/source/tarball/Percona-XtraDB-Cluster-${VERSION_UPSTREAM}-${VERSION_WSREP}.tar.gz"
      fi
    fi

  elif [[ "${PRODUCT}" = "psmdb" && "${BUILD_ARCH}" = "x86_64" ]]; then
     if [[ "${DISTRIBUTION}" = "jammy" ]]; then
       GLIBC_VERSION="glibc2.35"
     else
       GLIBC_VERSION="glibc2.17"
     fi
    if [[ -z ${VERSION_FULL} ]]; then
      if [[ ${SOURCE} = 0 ]]; then
	LINK=$(wget -qO- https://downloads.percona.com/downloads/percona-server-mongodb-${VERSION}/LATEST/binary/|grep -oE "percona-server-mongodb-${VERSION}\.[0-9]+-[0-9]+(\.[0-9]+)?-${BUILD_ARCH}.${GLIBC_VERSION}.tar.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://downloads.percona.com/downloads/percona-server-mongodb-${VERSION}/LATEST/binary/tarball/${LINK}"; fi
      else
        LINK=$(wget -qO- https://downloads.percona.com/downloads/percona-server-mongodb-${VERSION}/LATEST/source/|grep -oE "percona-server-mongodb-${VERSION}\.[0-9]+-[0-9]+(\.[0-9]+)?\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://downloads.percona.com/downloads/percona-server-mongodb-${VERSION}/LATEST/source/tarball/${LINK}"; fi
      fi
    else
      VERSION_UPSTREAM=$(echo "${VERSION_FULL}" | awk -F '-' '{print $1}')
      VERSION_PERCONA=$(echo "${VERSION_FULL}" | awk -F '-' '{print $2}')
      if [[ ${SOURCE} = 0 ]]; then
        LINK="https://downloads.percona.com/downloads/percona-server-mongodb-${VERSION}/percona-server-mongodb-${VERSION_UPSTREAM}-${VERSION_PERCONA}/binary/tarball/percona-server-mongodb-${VERSION_UPSTREAM}-${VERSION_PERCONA}-${OPT}-${BUILD_ARCH}.tar.gz"
      else
        LINK="https://downloads.percona.com/downloads/percona-server-mongodb-${VERSION}/percona-server-mongodb-${VERSION_UPSTREAM}-${VERSION_PERCONA}/source/tarball/percona-server-mongodb-${VERSION_UPSTREAM}-${VERSION_PERCONA}.tar.gz"
      fi
    fi

  elif [[ "${PRODUCT}" = "pxb" ]]; then
    if [[ "${VERSION}" == "2.4" ]]; then
      OPT="glibc2.12"
    elif [[ "${VERSION}" == "8.0" ]]; then
      OPT="glibc2.17"
    elif [[ "${DISTRIBUTION}" == "ubuntu" ]]; then
      OPT="bionic"
    else
      OPT="${DISTRIBUTION}"
    fi
    if [[ -z ${VERSION_FULL} ]]; then
      if [[ ${SOURCE} = 0 ]]; then
        #LINK=$(wget -qO- https://www.percona.com/downloads/XtraBackup/LATEST/binary/|grep -oE "percona-xtrabackup-[0-9]+\.[0-9]+\.[0-9]+-Linux-${BUILD_ARCH}\.tar\.gz"|head -n1)
        #VERSION_FULL=$(wget -qO- https://www.percona.com/downloads/Percona-XtraBackup-${VERSION}/LATEST/binary/|grep -oiE "Percona-XtraBackup-[0-9]+\.[0-9]+\.[0-9]+"|sort -Vr|head -n1|grep -oE "[0-9]+\.[0-9]+\.[0-9]+$")
        VERSION_FULL=$(wget -qO- https://www.percona.com/downloads/Percona-XtraBackup-${VERSION}/LATEST/binary/|grep -oiE "Percona-XtraBackup-[0-9]+\.[0-9]+\.[0-9]+|Percona-XtraBackup-[0-9]+\.[0-9]+\.[0-9]+\-[0-9]+[0-9]+"|sort -Vr|head -n1|grep -oE "[0-9]+\.[0-9]+\.[0-9]+$|[0-9]+\.[0-9]+\.[0-9]+\-[0-9]+[0-9]+$")
        TARBALL="percona-xtrabackup-${VERSION_FULL}-Linux-${BUILD_ARCH}.${OPT}.tar.gz"
        if [[ ! -z ${TARBALL} ]]; then LINK="https://www.percona.com/downloads/Percona-XtraBackup-${VERSION}/Percona-XtraBackup-${VERSION_FULL}/binary/tarball/${TARBALL}"; fi
      else
        LINK=$(wget -qO- https://www.percona.com/downloads/Percona-XtraBackup-${VERSION}/LATEST/source/|grep -oE "percona-xtrabackup-[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/Percona-XtraBackup-${VERSION}/LATEST/source/tarball/${LINK}"; fi
      fi
    else
      if [[ ${SOURCE} = 0 ]]; then
        LINK="https://www.percona.com/downloads/Percona-XtraBackup-${VERSION}/Percona-XtraBackup-${VERSION_FULL}/binary/tarball/percona-xtrabackup-${VERSION_FULL}-Linux-${BUILD_ARCH}.${OPT}.tar.gz"
      else
        LINK="https://www.percona.com/downloads/Percona-XtraBackup-${VERSION}/Percona-XtraBackup-${VERSION_FULL}/source/tarball/percona-xtrabackup-${VERSION_FULL}.tar.gz"
      fi
    fi

  elif [[ "${PRODUCT}" = "pmm-client" && "${BUILD_ARCH}" = "x86_64" ]]; then
    if [[ -z ${VERSION_FULL} ]]; then
      if [[ ${SOURCE} = 0 ]]; then
        LINK=$(wget -qO- https://www.percona.com/downloads/pmm-client/LATEST/binary/|grep -oE "pmm-client-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/pmm-client/LATEST/binary/tarball/${LINK}"; fi
      else
        LINK=$(wget -qO- https://www.percona.com/downloads/pmm-client/LATEST/source/|grep -oE "pmm-client-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/pmm-client/LATEST/source/tarball/${LINK}"; fi
      fi
    else
      if [[ ${SOURCE} = 0 ]]; then
        LINK="https://www.percona.com/downloads/pmm-client/pmm-client-${VERSION_FULL}/binary/tarball/pmm-client-${VERSION_FULL}.tar.gz"
      else
        LINK="https://www.percona.com/downloads/pmm-client/pmm-client-${VERSION_FULL}/source/tarball/pmm-client-${VERSION_FULL}.tar.gz"
      fi
    fi

  elif [[ "${PRODUCT}" = "pt" ]]; then
    if [[ -z ${VERSION_FULL} ]]; then
      if [[ ${SOURCE} = 0 ]]; then
        LINK=$(wget -qO- https://www.percona.com/downloads/percona-toolkit/LATEST/binary/|grep -oE "percona-toolkit-[0-9]+\.[0-9]+\.[0-9]+_${BUILD_ARCH}\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/percona-toolkit/LATEST/binary/tarball/${LINK}"; fi
      else
        LINK=$(wget -qO- https://www.percona.com/downloads/percona-toolkit/LATEST/source/|grep -oE "percona-toolkit-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz"|head -n1)
        if [[ ! -z ${LINK} ]]; then LINK="https://www.percona.com/downloads/percona-toolkit/LATEST/source/tarball/${LINK}"; fi
      fi
    else
      if [[ ${SOURCE} = 0 ]]; then
        LINK="https://www.percona.com/downloads/percona-toolkit/${VERSION_FULL}/binary/tarball/percona-toolkit-${VERSION_FULL}_${BUILD_ARCH}.tar.gz"
      else
        LINK="https://www.percona.com/downloads/percona-toolkit/${VERSION_FULL}/source/tarball/percona-toolkit-${VERSION_FULL}.tar.gz"
      fi
    fi

  elif [[ "${PRODUCT}" = "mysql" ]]; then
    if [[ -z ${VERSION_FULL} ]]; then
      if [[ ${SOURCE} = 0 ]]; then
        BASE_LINK="https://dev.mysql.com/get/Downloads/MySQL-${VERSION}/"
        TARBALL=$(wget -qO- https://dev.mysql.com/downloads/mysql/${VERSION}.html\?os\=2|grep -o -E "(mysql|MySQL)-${VERSION}\.[0-9]+.*${BUILD_ARCH}\.tar\..."|grep -v "mysql-test"|head -n1)
        LINK="${BASE_LINK}${TARBALL}"
      else
        BASE_LINK="https://dev.mysql.com/get/Downloads/MySQL-${VERSION}/"
        TARBALL=$(wget -qO- https://dev.mysql.com/downloads/mysql/${VERSION}.html\?os\=src|grep -o -E "(mysql|MySQL)-${VERSION}\.[0-9]+\.tar\..."|head -n1)
        LINK="${BASE_LINK}${TARBALL}"
      fi
    else
      if [[ ${SOURCE} = 0 ]]; then
        BASE_LINK="https://dev.mysql.com/get/Downloads/MySQL-${VERSION}/"
        TARBALL=$(wget -qO- https://dev.mysql.com/downloads/mysql/${VERSION}.html\?os\=2|grep -o -E "(mysql|MySQL)-${VERSION_FULL}.*${BUILD_ARCH}.tar.gz"|grep -v "mysql-test"|head -n1)
        LINK="${BASE_LINK}${TARBALL}"
      else
        LINK="https://dev.mysql.com/get/Downloads/MySQL-${VERSION}/mysql-${VERSION_FULL}.tar.gz"
      fi
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
        if [[ ${SOURCE} = 0 ]]; then
          DIRECTORY="${DIRECTORY}/bintar-linux-systemd-${BUILD_ARCH_TMP}/"
          TARBALL="mariadb-${VERSION_FULL}-linux-systemd-${BUILD_ARCH}.tar.gz"
          LINK="${BASE_LINK}${DIRECTORY}${TARBALL}"
        else
          DIRECTORY="${DIRECTORY}/source/"
          TARBALL="mariadb-${VERSION_FULL}.tar.gz"
          LINK="${BASE_LINK}${DIRECTORY}${TARBALL}"
        fi
      fi
    else
      if [[ ${SOURCE} = 0 ]]; then
        LINK="https://downloads.mariadb.org/f/mariadb-${VERSION_FULL}/bintar-linux-${BUILD_ARCH_TMP}/mariadb-${VERSION_FULL}-linux-${BUILD_ARCH}.tar.gz"
      else
        LINK="https://downloads.mariadb.org/f/mariadb-${VERSION_FULL}/source/mariadb-${VERSION_FULL}.tar.gz"
      fi
    fi # version_full

  elif [[ "${PRODUCT}" = "proxysql" ]]; then
    if [[ "${DISTRIBUTION}" = "ubuntu" ]]; then DISTRIBUTION="xenial"; fi
    BASE_LINK="https://www.percona.com/downloads/proxysql/"
    if [[ -z ${VERSION_FULL} ]]; then
        VERSION=$(wget -qO- ${BASE_LINK}|grep -o "proxysql-[0-9]*.[0-9]*.[0-9]*"|tail -n1|sed 's/^.*-//')
      if [[ ${SOURCE} = 0 ]]; then
        TARBALL="proxysql-${VERSION}-Linux-${DISTRIBUTION}-${BUILD_ARCH}.tar.gz"
        LINK="${BASE_LINK}proxysql-${VERSION}/binary/tarball/${TARBALL}"
      else
        LINK="${BASE_LINK}proxysql-${VERSION}/source/tarball/proxysql-${VERSION}.tar.gz"
      fi
    else
      if [[ ${SOURCE} = 0 ]]; then
        LINK="${BASE_LINK}proxysql-${VERSION_FULL}/binary/tarball/proxysql-${VERSION_FULL}-Linux-${DISTRIBUTION}-${BUILD_ARCH}.tar.gz"
      else
        LINK="${BASE_LINK}proxysql-${VERSION_FULL}/source/tarball/proxysql-${VERSION_FULL}.tar.gz"
      fi
    fi

  elif [[ "${PRODUCT}" = "mongodb" ]]; then
    if [[ ${SOURCE} = 0 ]]; then
      BASE_LINK="http://fastdl.mongodb.org/linux/"
    else
      BASE_LINK="http://fastdl.mongodb.org/src/"
    fi
    DISTRIBUTION="-${DISTRIBUTION}";
    if [[ -z ${VERSION_FULL} ]]; then
      if [[ ${SOURCE} = 0 ]]; then
	TARBALL=$(wget -qO- https://www.mongodb.com/try/download/community | grep -o -E "mongodb-linux-x86_64${DISTRIBUTION}-${VERSION}\..{1,6}\.tgz" | grep -viE "(\-rc|\-beta|\-alpha)+" | head -n1)
        LINK="${BASE_LINK}${TARBALL}"
      else
        TARBALL=$(wget -qO- https://www.mongodb.com/try/download/community | grep -o -E "mongodb-src-r${VERSION}\..{1,6}\.tar.gz" | grep -viE "(\-rc|\-beta|\-alpha)+" | head -n1)
        LINK="${BASE_LINK}${TARBALL}"
      fi
    else
      if [[ ${SOURCE} = 0 ]]; then
        LINK="${BASE_LINK}mongodb-linux-x86_64-${VERSION_FULL}.tgz"
      else
        LINK="${BASE_LINK}mongodb-src-r${VERSION_FULL}.tar.gz"
      fi
    fi

  elif [[ "${PRODUCT}" = "vault" ]]; then
    BASE_LINK="https://releases.hashicorp.com/vault/"
    if [ ${BUILD_ARCH} = "x86_64" ]; then
      BUILD_ARCH="amd64"
    fi

    if [[ -z ${VERSION_FULL} ]]; then
      VERSION_FULL=$(wget -qO- https://releases.hashicorp.com/vault/ |grep -o "vault_.*"|grep -vE "alpha|beta|rc|ent"|sed "s:</a>::"|sed "s:vault_::"|head -n1)
      TARBALL="vault_${VERSION_FULL}_linux_${BUILD_ARCH}.zip"
      LINK="${BASE_LINK}${VERSION_FULL}/${TARBALL}"
    else
      LINK="${BASE_LINK}${VERSION_FULL}/vault_${VERSION_FULL}_linux_${BUILD_ARCH}.zip"
    fi

  elif [[ "${PRODUCT}" = "postgresql" ]]; then
    BASE_LINK="https://get.enterprisedb.com/postgresql/"
    if [ ${BUILD_ARCH} = "x86_64" ]; then
      BUILD_ARCH="-x64"
    else
      BUILD_ARCH=""
    fi

    if [[ -z ${VERSION_FULL} ]]; then
      TARBALL=$(wget -qO- https://www.enterprisedb.com/download-postgresql-binaries|grep -oE "postgresql-${VERSION}.*?${BUILD_ARCH}-.*?.tar.gz"|head -n 1)
      LINK="${BASE_LINK}${TARBALL}"
    else
      LINK="${BASE_LINK}postgresql-${VERSION_FULL}-1-linux${BUILD_ARCH}-binaries.tar.gz"
    fi

  else
    echo "Unrecognized product!";
    exit 1
  fi # last product
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
