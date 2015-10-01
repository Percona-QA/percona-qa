#!/bin/bash

# This script will enable the Percona apt/yum Repository

# david dot bennett at percona dot com - 2015-08-11

# Usage: ./percona_repo_install.sh [ -k|--keyid {gnupg key id} ]
#                                  [ -r|--rpmver {rpm version string} ]

# Make sure we are running as root

if [ ! "${EUID}" == 0 ]; then
  echo >&2 "This script must be run with root permissions."
  exit 1;
fi

# Use bash net redirections to verify
# apt distribution name support

function checkdist {
  distver=$1
  exec 3<>/dev/tcp/repo.percona.com/80
  cat <<_EOH_ >&3
HEAD /apt/dists/${distver}/Release.gpg HTTP/1.1
Host: repo.percona.com
Connection: close

_EOH_
  read rawResponse <&3;
  checkdistReturn=$(echo "${rawResponse}" | cut -d' ' -f2)
  exec 3>&-
}

# apt installer for Debian/Ubuntu

function apt_install {

  # Check to see if we have all the commands we need

  for cmd in "apt-get" "apt-key" "grep" "awk" "head" "getopt"; do
    hash ${cmd} &> /dev/null
    if [ $? -eq 1 ]; then
      echo >&2 "This system does not have '${cmd}', install before running."
      exit 1;
    fi
  done

  # everything looks good

  echo "Enabling the Percona apt repository..."

  # get key id

  KEYID='1C4CBDCDCD2EFD2A'
  OPTS=$(getopt -o k: -l keyid: -n 'parse-options' -- "$@")
  eval set -- "$OPTS"

  while true; do
    case "$1" in
      -k | --keyid ) KEYID="$2"; shift; shift ;;
      * ) break;
    esac
  done

  # error log

  errorLog=$(mktemp -t percona-apt-install-XXXXX.log)

  # install Percona apt key

  apt-key adv --keyserver keys.gnupg.net --recv-keys "${KEYID}" >> "${errorLog}" 2>&1

  apt-key list | grep -qi percona || {
    echo "Something went wrong during installation of the Percona gnupg key."
    echo "Check log: ${errorLog}"
    exit 1;
  }

  # get the distribution version

  distver=$(grep '^deb ' /etc/apt/sources.list | awk '{print $3}' | grep -Fv '-' | head -n1)

  if [ "${distver}" == "" ]; then
    echo >&2 "Unable to determine distribution version."
    exit 1;
  fi

  # check that release is supported by Percona apt repository

  checkdist "${distver}"
  if [ ! "${checkdistReturn}" == "200" ]; then
    echo >&2 "Distribution: '${distver}' is not supported."
    exit 1;
  fi

  # Create percona.list in apt configuration

  mkdir -p /etc/apt/sources.list.d

  cat <<_EOF_ >/etc/apt/sources.list.d/percona.list
deb http://repo.percona.com/apt ${distver} main
deb-src http://repo.percona.com/apt ${distver} main
_EOF_

  # update the repository

  apt-get update -y >> "${errorLog}" 2>&1

  # check and report

  echo '-----'
  if apt-cache madison percona-server-server | grep -q 'repo\.percona'; then
    echo 'The Percona apt repository is ready to use.'
    exit 0;
  else
    echo "Something went wrong during installation of the Percona apt repository."
    echo "Check log: ${errorLog}"
    exit 1;
  fi

}

# thank you Dennis Williamson on stackoverflow (Q#:4023830)

vercomp () {
    if [[ "$1" == "$2" ]]
    then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

# yum installer for RHEL/Centos/Oracle

function yum_install {

  # Check to see if we have all the commands we need

  for cmd in "yum" "rpm" "grep" "awk"; do
    hash ${cmd} &> /dev/null
    if [ $? -eq 1 ]; then
      echo >&2 "This system does not have '${cmd}', install before running."
      exit 1;
    fi
  done

  # everything looks good

  echo "Enabling the Percona yum repository..."

  # get version

  RPMVER='0.1-3'
  OPTS=$(getopt -o r: -l rpmver: -n 'parse-options' -- "$@")
  eval set -- "$OPTS"

  while true; do
    case "$1" in
      -r | --rpmver ) RPMVER="$2"; shift; shift ;;
      * ) break;
    esac
  done

  # error log

  errorLog=$(mktemp -t percona-yum-install-XXXXX.log)

  # install Percona yum repository rpm

  # we still need rpm to install http on Centos 5 (yum 3.2.22)
  rpmurl="http://www.percona.com/downloads/percona-release/redhat/${RPMVER}/percona-release-${RPMVER}.noarch.rpm"
  yumver=$(yum --version | head -n1)
  vercomp "${yumver}" "3.2.26"
  if [ $? == 2 ]; then
    rpm -ivh "${rpmurl}" >> "${errorLog}" 2>&1
  else
    yum install -y "${rpmurl}" >> "${errorLog}" 2>&1
  fi

  # check and report

  echo '-----'
  if yum --disablerepo=* --enablerepo=percona-release* list | awk '{print $3}' | grep -Fiq percona; then
    echo 'The Percona yum repository is ready to use.'
    exit 0;
  else
    echo "Something went wrong during installation of the Percona yum repository."
    echo "Check log: ${errorLog}"
    exit 1;
  fi

}

# main script

if hash apt-get &> /dev/null; then
  apt_install "$@"
elif hash yum &> /dev/null; then
  yum_install "$@"
fi
