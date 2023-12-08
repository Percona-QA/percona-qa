#!/bin/bash

###########################################################################################
# Created By Manish Chawla, Percona LLC                                                    #
# Modified By Mohit Joshi, Percona LLC                                                     #
# This script installs pxb2.4/pxb80/pxb8x-innovation from the main/testing repo            #
# Usage:                                                                                   #
# 1. Run the script as: ./pkg_install_tests.sh pxb24/pxb80/pxb8x-innovation main/testing   #
# 3. Logs are available in: $HOME/install_log                                              #
############################################################################################

log="$HOME/install_log"

help() {
  echo "Please run the script with parameters: <pxb-version=pxb24/pxb80/pxb8x-innovation> <repo=main/testing>"
  exit 1
}

if [ "$#" -ne 2 ]; then
    help
fi

pxb_version="$1"
repo="$2"

if [ -f /usr/bin/yum ]; then
    install_cmd="sudo yum install -y"
    remove_cmd="sudo yum remove -y"
    list_cmd="sudo yum list installed"
    if [ "$pxb_version" = "pxb24" ]; then
        pxb_packages="percona-xtrabackup-24 percona-xtrabackup-test-24 percona-xtrabackup-24-debuginfo"
    elif [ "$pxb_version" = "pxb80" ]; then
        pxb_packages="percona-xtrabackup-80 percona-xtrabackup-test-80 percona-xtrabackup-80-debuginfo"
    elif [ "$pxb_version" = "pxb8x-innovation" ]; then
        pxb_packages="percona-xtrabackup-81 percona-xtrabackup-test-81 percona-xtrabackup-81-debuginfo"
    else
        echo "Invalid pxb version $pxb_version"
        help
    fi
else
    install_cmd="sudo apt-get install -y"
    remove_cmd="sudo apt-get remove -y"
    list_cmd="sudo apt list --installed"
    if [ "$pxb_version" = "pxb24" ]; then
        pxb_package="percona-xtrabackup-24"
        pxb_addon_packages="percona-xtrabackup-test-24 percona-xtrabackup-dbg-24"
    elif [ "$pxb_version" = "pxb80" ]; then
        pxb_package="percona-xtrabackup-80"
        pxb_addon_packages="percona-xtrabackup-test-80 percona-xtrabackup-dbg-80"
    elif [ "$pxb_version" = "pxb8x-innovation" ]; then
        pxb_package="percona-xtrabackup-81"
        pxb_packages="percona-xtrabackup-test-81 percona-xtrabackup-dbg-81"
    else
        echo "Invalid pxb version $pxb_version"
        help
    fi
fi

if [ "$repo" = "main" ]; then
    install_repo=release
elif [ "$repo" = "testing" ]; then
    install_repo=testing
fi

install_pxb_package() {
    echo "Checking if percona-xtrabackup is already installed" 
    if ${list_cmd} | grep "$pxb_package" >"${log}" ; then
        echo "Uninstalling $pxb_version packages"
        ${remove_cmd} ${pxb_package} >>"${log}"
        ${remove_cmd} ${pxb_addon_packages} >>"${log}"
    else
        echo "PXB packages are not installed"
    fi

    ${remove_cmd} percona-release >>"${log}"

    if [ -f /usr/bin/apt ]; then
        sudo apt-get update >>"${log}"
        wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
        sudo dpkg -i percona-release_latest.generic_all.deb
    else
        ${install_cmd} https://repo.percona.com/yum/percona-release-latest.noarch.rpm >>"${log}"
    fi

    echo "Installing $pxb_version packages from the $repo repo"
    sudo percona-release enable-only tools $install_repo
    if [ -f /usr/bin/apt ]; then
        sudo apt-get update >>"${log}"
    fi

    if ! ${install_cmd} ${pxb_package} >>"${log}" ; then
        echo "ERR: $pxb_version packages could not be installed from the $repo repo"
        exit 1
    else
        ${install_cmd} ${pxb_addon_packages}
        echo "$pxb_version packages successfully installed with version: "
        xtrabackup --version
    fi
}

install_pxb_package
