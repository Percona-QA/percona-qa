#!/usr/bin/env bash
# Created by Tomislav Plavcic, Percona LLC

PRODUCT=""
VERSION=""
DIST_REL=""
LINK=""
DOWNLOAD=0
SOURCE=0
DEPS_INDEX=0
DEPS_LIST=('wget' 'jq' 'curl')
MISSED_DEP=false

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

# Check dependencies and exit if there are missing ones
while [ $DEPS_INDEX -lt 3 ]
do
  if [[ -z "$(which ${DEPS_LIST[$DEPS_INDEX]})" ]]; then
    MISSED_DEP=true
    echo "ERROR: ${DEPS_LIST[$DEPS_INDEX]} is required for proper functioning of this script!"
  fi
  (( DEPS_INDEX++ ))
done

if $MISSED_DEP; then
  exit 1
fi

if [[ -z "${VERSION}" ]] && [[ "${PRODUCT}" = "ps" || "${PRODUCT}" = "pxc" ]]; then VERSION="8.0"; fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "mysql" ]]; then VERSION="8.0"; fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "pxb" ]]; then VERSION="8.0"; fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "mariadb" ]]; then VERSION="10.4"; fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "psmdb" ]]; then VERSION="6.0"; fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "mongodb" ]]; then VERSION="4.2"; fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "postgresql" ]]; then
  VERSION=$(wget -qO- https://www.enterprisedb.com/download-postgresql-binaries|grep -oE "postgresql-.*-x64-.*.tar.gz"|head -n1|grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?"|head -n1)
fi
if [[ -z "${VERSION}" && ( "${PRODUCT}" = "proxysql" || "${PRODUCT}" = "proxysql2" ) ]]; then
  VERSION=$(curl -s -X POST -d "version=${PRODUCT}" https://www.percona.com/products-api.php | grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" | sort -Vr |uniq |head -n1)
fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "pt" ]]; then
  VERSION=$(curl -s -X POST -d "version=percona-toolkit" https://www.percona.com/products-api.php | grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" | sort -Vr |uniq |head -n1)
fi
if [[ -z "${VERSION}" && "${PRODUCT}" = "pmm-client" ]]; then
  VERSION=$(curl -s -X POST -d "version=pmm2" https://www.percona.com/products-api.php | grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" | sort -Vr |uniq |head -n1)
fi

if [[ "${DISTRIBUTION}" = *"-"* ]]; then
  DIST_REL=$(echo "${DISTRIBUTION}" | cut -d- -f2)
  DISTRIBUTION=$(echo "${DISTRIBUTION}" | cut -d- -f1)
fi

function find_link () {
  local product_name="$1"
  if [[ -z "${VERSION_FULL}" ]]; then
      PRODUCT_FULL=$(curl -s -X POST -d "version=${product_name}${DL_VERSION}" https://www.percona.com/products-api.php | grep -oE "${product_name}-${VERSION}\.[0-9]+(-[0-9]+)?(\.[0-9]+)?" | sort -Vr |uniq |head -n1)
  else
    if [[ "${VERSION_FULL}" = *"-"*"."* ]]; then
      VERSION_UPSTREAM=$(echo "${VERSION_FULL}" | awk -F '-' '{print $1}')
      VERSION_PERCONA=$(echo "${VERSION_FULL}" | awk -F '-' '{print "-"$2}')
      PATTERN=${VERSION_PERCONA}
    elif [[ "${VERSION_FULL}" = *"-"* ]]; then
      VERSION_UPSTREAM=$(echo "${VERSION_FULL}" | awk -F '-' '{print $1}')
      VERSION_PERCONA="$(echo "${VERSION_FULL}" | awk -F '-' '{print "-"$2}')"
      PATTERN="\\${VERSION_PERCONA}(\.[0-9]+)?"
    else
      VERSION_UPSTREAM=${VERSION_FULL}
      PATTERN="(-[0-9]+)?(\.[0-9]+)?"
    fi
    PRODUCT_FULL=$(curl -s -X POST -d "version=${product_name}${DL_VERSION}" https://www.percona.com/products-api.php | grep -oE "${product_name}-${VERSION_UPSTREAM}(${PATTERN})?" | sort -Vr |uniq |head -n1)
  fi
  if [[ "${SOURCE}" = 0 ]]; then
      LINK=$(curl -s -X POST -d "version_files=${PRODUCT_FULL}&software_files=binary" https://www.percona.com/products-api.php| jq -r '.[]|.link'|grep -E "(${PATTERN}).+${BUILD_ARCH}.${SSL_VER}${GLIBC_VERSION}.tar.gz$" | sort -Vr |uniq |head -n1)
  else
      LINK=$(curl -s -X POST -d "version_files=${PRODUCT_FULL}&software_files=source" https://www.percona.com/products-api.php| jq -r '.[]|.link'|grep -iE "${PRODUCT_FULL}(${PATTERN})?.+\.tar.gz$" | sort -Vr |uniq |head -n1)
  fi
}

get_link(){
  if [[ "${DISTRIBUTION}" = "ubuntu" && "${DIST_REL}" = "jammy" ]]; then
    GLIBC_VERSION="glibc2.35"
    SSL_VER=""
  else
    GLIBC_VERSION="glibc2.17"
    SSL_VER=""
  fi

  if [[ $(grep -o "\." <<< "${VERSION}" | wc -l) -gt 1 ]]; then
    VERSION_FULL=${VERSION}
    VERSION=$(echo "${VERSION_FULL}"|awk -F '.' '{print $1"."$2}')
  else
    VERSION_FULL=""
  fi

#### PS
  if [[ "${PRODUCT}" = "ps" ]]; then
    if [[ "${VERSION}" = "5.6" ]]; then
      GLIBC_VERSION=""
      SSL_VER="ssl101"
    fi
    DL_VERSION="-${VERSION}"
    find_link "Percona-Server"

#### PXC
  elif [[ "${PRODUCT}" = "pxc" ]]; then
    DL_VERSION="-${VERSION//./}"
    find_link "Percona-XtraDB-Cluster"

#### PXB
  elif [[ "${PRODUCT}" = "pxb" ]]; then
    DL_VERSION="-${VERSION}"
    # GLIBC_VERSION glibc2.12 was used in PXB 2.4.27 and before
    versions_string="$VERSION_FULL
    2.4.27"
    if [[ "${VERSION_FULL}" = "2.4."* && "$versions_string" == "$(sort --version-sort <<< "$versions_string")" ]]; then
      GLIBC_VERSION="glibc2.12"
      SSL_VER=""
    fi
    find_link "Percona-XtraBackup"

#### PSMDB
  elif [[ "${PRODUCT}" = "psmdb" && "${BUILD_ARCH}" = "x86_64" ]]; then
     if [[ "${DISTRIBUTION}" = "jammy" ]]; then
       GLIBC_VERSION="glibc2.35"
     else
       GLIBC_VERSION="glibc2.17"
     fi
    DL_VERSION="-${VERSION}"
    find_link "percona-server-mongodb"

#### PT
  elif [[ "${PRODUCT}" = "pt" ]]; then
    if [[ -z "${VERSION_FULL}" ]]; then
      PRODUCT_FULL=$(curl -s -X POST -d "version=percona-toolkit" https://www.percona.com/products-api.php | grep -oE "${VERSION}\.[0-9]+" | sort -Vr |uniq |head -n1)
    else
      PRODUCT_FULL=$(curl -s -X POST -d "version=percona-toolkit" https://www.percona.com/products-api.php | grep -oE "${VERSION_FULL}" | sort -Vr |uniq |head -n1)
    fi
    if [[ "${SOURCE}" = 0 ]]; then
        LINK=$(curl -s -X POST -d "version_files=${PRODUCT_FULL}&software_files=binary" https://www.percona.com/products-api.php| jq -r '.[]|.link'|grep -E "*${BUILD_ARCH}.tar.gz$" | sort -Vr |uniq |head -n1)
    else
        LINK=$(curl -s -X POST -d "version_files=${PRODUCT_FULL}&software_files=source" https://www.percona.com/products-api.php| jq -r '.[]|.link'|grep -iE "${PRODUCT_FULL}(${PATTERN})?.+\.tar.gz$" | sort -Vr |uniq |head -n1)
    fi

#### PMM-CLIENT
  elif [[ "${PRODUCT}" = "pmm-client" && "${BUILD_ARCH}" = "x86_64" ]]; then
    if [[ "${DISTRIBUTION}" = "jammy" ]]; then
       GLIBC_VERSION="glibc2.35"
    else
       GLIBC_VERSION="glibc2.17"
    fi
    if [[ -z "${VERSION_FULL}" ]]; then
      PRODUCT_FULL=$(curl -s -X POST -d "version=pmm2" https://www.percona.com/products-api.php | grep -oE "${VERSION}\.[0-9]+" | sort -Vr |uniq |head -n1)
    else
      PRODUCT_FULL=$(curl -s -X POST -d "version=pmm2" https://www.percona.com/products-api.php | grep -oE "${VERSION_FULL}" | sort -Vr |uniq |head -n1)
    fi
    if [[ "${SOURCE}" = 0 ]]; then
        LINK=$(curl -s -X POST -d "version_files=${PRODUCT_FULL}&software_files=binary" https://www.percona.com/products-api.php| jq -r '.[]|.link'|grep -E "*.tar.gz$" | sort -Vr |uniq |head -n1)
    else
        LINK=$(curl -s -X POST -d "version_files=${PRODUCT_FULL}&software_files=source" https://www.percona.com/products-api.php| jq -r '.[]|.link'|grep -iE "${PRODUCT_FULL}(${PATTERN})?.+\.tar.gz$" | sort -Vr |uniq |head -n1)
    fi

#### PROXYSQL
  elif [[ "${PRODUCT}" = "proxysql" || "${PRODUCT}" = "proxysql2" ]]; then
    if [[ "${PRODUCT}" = "proxysql" ]]; then
      if [[ "${DISTRIBUTION}" = "ubuntu" ]]; then DISTRIBUTION="xenial"; fi
    elif [[ "${PRODUCT}" = "proxysql2" ]]; then
      DISTRIBUTION=${GLIBC_VERSION}
    fi
    if [[ -z "${VERSION_FULL}" ]]; then
      PRODUCT_FULL=$(curl -s -X POST -d "version=${PRODUCT}" https://www.percona.com/products-api.php | grep -oE "${PRODUCT}-${VERSION}\.[0-9]+" | sort -Vr |uniq |head -n1)
    else
      PRODUCT_FULL=$(curl -s -X POST -d "version=${PRODUCT}" https://www.percona.com/products-api.php | grep -oE "${PRODUCT}-${VERSION_FULL}" | sort -Vr |uniq |head -n1)
    fi
    if [[ "${SOURCE}" = 0 ]]; then
        LINK=$(curl -s -X POST -d "version_files=${PRODUCT_FULL}&software_files=binary" https://www.percona.com/products-api.php| jq -r '.[]|.link'|grep -E "(${DISTRIBUTION})*.tar.gz$" | sort -Vr |uniq |head -n1)
    else
        LINK=$(curl -s -X POST -d "version_files=${PRODUCT_FULL}&software_files=source" https://www.percona.com/products-api.php| jq -r '.[]|.link'|grep -iE "${PRODUCT_FULL}(${PATTERN})?.+\.tar.gz$" | sort -Vr |uniq |head -n1)
    fi

#### MYSQL
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

#### MARIADB
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
    fi

#### MONGODB
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

#### VAULT
 elif [[ "${PRODUCT}" = "vault" ]]; then
    BASE_LINK="https://releases.hashicorp.com/vault/"
    if [ ${BUILD_ARCH} = "x86_64" ]; then
      BUILD_ARCH="amd64"
    elif [[ "${BUILD_ARCH}" = "aarch64" ]]; then
      BUILD_ARCH="arm64"
    fi

    if [[ -z ${VERSION_FULL} ]]; then
      VERSION_FULL=$(wget -qO- https://releases.hashicorp.com/vault/ |grep -o "vault_.*"|grep -vE "alpha|beta|rc|ent"|sed "s:</a>::"|sed "s:vault_::"|head -n1)
      TARBALL="vault_${VERSION_FULL}_linux_${BUILD_ARCH}.zip"
      LINK="${BASE_LINK}${VERSION_FULL}/${TARBALL}"
    else
      LINK="${BASE_LINK}${VERSION_FULL}/vault_${VERSION_FULL}_linux_${BUILD_ARCH}.zip"
    fi

#### POSTGRESQL
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
  fi
}

get_link
if [[ -z ${LINK} ]]; then
  exit 1
elif [[ $(echo $LINK|grep -o https|wc -l) -gt 1 ]];then
  echo -e "ERROR: script returns more than one link:\n${LINK}\nPlease re-check script"
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
