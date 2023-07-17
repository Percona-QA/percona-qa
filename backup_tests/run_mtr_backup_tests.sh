#!/bin/bash

############################################################################
# Created By Manish Chawla, Percona LLC                                    #
# This script runs the mtr tests for pxb release tarballs                  #
# Usage:                                                                   #
# 1. Clone package-testing repo: github.com/Percona-QA/package-testing     #
# 2. Set paths in this script:                                             #
#    package_testing_dir, test_home_dir, logdir                            #
# 3. Run the script as: ./run_mtr_backup_tests.sh pxb24/pxb80 main/testing #
# 4. Logs are available in: logdir                                         #
############################################################################

# Set script variables
export package_testing_dir="$HOME/package-testing"
export test_home_dir="$HOME"
export logdir="$HOME/backuplogs"

check_usage() {
  # This function checks that the required parameters are passed to the script
  if [ "$#" -lt 2 ]; then
    echo "This script requires the product parameters: pxb24/pxb80 main/testing"
    echo "Usage: $0 <product> <repo>"
    exit 1
  fi
}

check_dependencies() {
  # This function checks if the required dependencies are available
  if [[ ! -f "${package_testing_dir}/VERSIONS" ]]; then
    echo "ERR: The VERSIONS file does not exist in $package_testing_dir. Please clone the package-testing repo and run again."
    exit 1
  fi

  pushd "${package_testing_dir}" >/dev/null 2>&1 || exit
  git checkout master >/dev/null
  git pull >/dev/null
  popd >/dev/null 2>&1 || exit
}

download_tarballs() {
  # This function downloads the pxb and ps release tarballs
  # PXB minimal tarballs do not contain the mtr tests hence are not used in this script
  log="${logdir}/run_mtr_tests_$(date +"%d_%m_%Y_%M")_log"
  >${log}

  source "${package_testing_dir}"/VERSIONS

  # Clean existing directories
  for dir in pxb80 pxb24 percona_server; do
    if [ -d "${dir}" ]; then
      rm -r "${dir}"
    fi
  done

  if [ "$1" = "pxb80" ]; then
    product=pxb80
    version=${PXB80_VER}
    major_version="${PXB80_VER}"
    minor_version="${PXB80PKG_VER}"
    echo "Downloading ${1} latest version..." | tee -a "${log}"
    if [ "$2" = "main" ]; then
      wget https://www.percona.com/downloads/Percona-XtraBackup-LATEST/Percona-XtraBackup-${major_version}-${minor_version}/binary/tarball/percona-xtrabackup-${major_version}-${minor_version}-Linux-x86_64.glibc2.17.tar.gz
      pxb_tarball_dir="percona-xtrabackup-${major_version}-${minor_version}-Linux-x86_64.glibc2.17"
    else
      # Use testing repo/link to download tarball
      wget https://downloads.percona.com/downloads/TESTING/pxb-${major_version}-${minor_version}/percona-xtrabackup-${major_version}-${minor_version}-Linux-x86_64.glibc2.17.tar.gz
      pxb_tarball_dir="percona-xtrabackup-${major_version}-${minor_version}-Linux-x86_64.glibc2.17"
    fi

    echo "Downloading Percona Server ${PS80_VER} version..." | tee -a "${log}"
    wget https://downloads.percona.com/downloads/Percona-Server-LATEST/Percona-Server-${PS80_VER}/binary/tarball/Percona-Server-${PS80_VER}-Linux.x86_64.glibc2.17.tar.gz
    ps_tarball_dir="Percona-Server-${PS80_VER}-Linux.x86_64.glibc2.17"

  elif [ "$1" = "pxb24" ]; then
    product="pxb24"
    version="${PXB24_VER}"

    echo "Downloading ${1} latest version..." | tee -a "${log}"
    if [ "$2" = "main" ]; then
      wget https://www.percona.com/downloads/Percona-XtraBackup-2.4/Percona-XtraBackup-${version}/binary/tarball/percona-xtrabackup-${version}-Linux-x86_64.glibc2.12.tar.gz
      pxb_tarball_dir="percona-xtrabackup-${version}-Linux-x86_64.glibc2.12"
    else
      # Use testing repo/link to download tarball
      wget https://downloads.percona.com/downloads/TESTING/pxb-${version}/percona-xtrabackup-${version}-Linux-x86_64.glibc2.12.tar.gz
      pxb_tarball_dir="percona-xtrabackup-${version}-Linux-x86_64.glibc2.12"
    fi

    echo "Downloading Percona Server ${PS57_VER} version..." | tee -a "${log}"
    wget https://downloads.percona.com/downloads/Percona-Server-5.7/Percona-Server-${PS57_VER}/binary/tarball/Percona-Server-${PS57_VER}-Linux.x86_64.glibc2.17.tar.gz
    ps_tarball_dir="Percona-Server-${PS57_VER}-Linux.x86_64.glibc2.17"
  fi

  echo "Unpacking PXB binary tarball" | tee -a "${log}"
  tar -xzf ${pxb_tarball_dir}.tar.gz
  mv ${pxb_tarball_dir} ${product}
  pxb_tarball_dir=${product}

  echo "Unpacking Percona Server binary tarball" | tee -a "${log}"
  tar -xzf ${ps_tarball_dir}.tar.gz
  mv ${ps_tarball_dir} $test_home_dir/percona_server
  ps_tarball_dir="${test_home_dir}/percona_server"

  echo "Check version for binaries in tarball: ${pxb_tarball_dir}" | tee -a "${log}"
  for binary in xtrabackup xbstream xbcloud xbcrypt; do
    version_check=$("${pxb_tarball_dir}"/bin/$binary --version 2>&1| grep -c "${version}")
    installed_version=$("${pxb_tarball_dir}"/bin/$binary --version 2>&1|tail -1|awk '{print $3}')
    if [ "${version_check}" -eq 0 ]; then
      echo "${binary} version is incorrect! Expected version: ${version} Installed version: ${installed_version}"
      exit 1
    else
      echo "${binary} version is correctly displayed as: ${version}" | tee -a "${log}"
    fi
  done
}

run_tests() {
  # This function runs the mtr tests using the downloaded tarballs
  echo "Running PXB tests" | tee -a "${log}"
  if [ "$1" = "pxb80" ]; then
    pushd "$pxb_tarball_dir/percona-xtrabackup-8.0-test/test" >/dev/null 2>&1 || exit
  else
    pushd "$pxb_tarball_dir/percona-xtrabackup-2.4-test" >/dev/null 2>&1 || exit
  fi

  if ! ./run.sh -f -d "${ps_tarball_dir}" | tee -a "${log}"; then
    echo "ERR: Tests failed. Please check the logs at $log"
    popd >/dev/null 2>&1 || exit
    exit 1
  else
    echo "Tests passed. Logs are available at $log"
  fi
  popd >/dev/null 2>&1 || exit
}

echo "################################## Running Tests ##################################"
check_usage "$@"
check_dependencies
download_tarballs "$@"
run_tests "$@"
