#!/bin/bash

###############################################################################
# Created By Manish Chawla, Percona LLC                                       #
# Modified By Mohit Joshi, Percona LLC                                        #
# This script installs pxb2.4/pxb80/pxb81 from the main/testing repo          #
# Usage:                                                                      #
# 1. Run the script as: ./pkg_install_tests.sh pxb24/pxb80/pxb81 main/testing #
# 3. Logs are available in: $HOME/install_log                                 #
###############################################################################

log="$HOME/install_log"
if [ "$#" -ne 2 ]; then
    echo "Please run the script with parameters: <pxb-version=pxb24/pxb80/pxb81> <repo=main/testing>"
    exit 1
fi

pxb_version="$1"
repo="$2"

if [ -f /usr/bin/yum ]; then
    install_cmd="sudo yum install -y"
    remove_cmd="sudo yum remove -y"
    list_cmd="sudo yum list installed"
    pxb24_packages="percona-xtrabackup-24 percona-xtrabackup-test-24 percona-xtrabackup-24-debuginfo"
    pxb80_packages="percona-xtrabackup-80 percona-xtrabackup-test-80 percona-xtrabackup-80-debuginfo"
    pxb81_packages="percona-xtrabackup-81 percona-xtrabackup-test-81 percona-xtrabackup-81-debuginfo"
else
    install_cmd="sudo apt-get install -y"
    remove_cmd="sudo apt-get remove -y"
    list_cmd="sudo apt list --installed"
    pxb24_packages="percona-xtrabackup-24 percona-xtrabackup-test-24 percona-xtrabackup-dbg-24"
    pxb80_packages="percona-xtrabackup-80 percona-xtrabackup-test-80 percona-xtrabackup-dbg-80"
    pxb81_packages="percona-xtrabackup-81 percona-xtrabackup-test-81 percona-xtrabackup-dbg-81"
fi

install_pxb_package() {
    echo "Checking if percona-xtrabackup is already installed" 
    if ${list_cmd} | grep "percona-xtrabackup-24" >"${log}" ; then
        echo "Uninstalling PXB 2.4 packages"
        ${remove_cmd} ${pxb24_packages} >>"${log}"
    elif ${list_cmd} |grep "percona-xtrabackup-80" >"${log}" ; then
        echo "Uninstalling PXB 8.0 packages"
        ${remove_cmd} ${pxb80_packages} >>"${log}"
    elif ${list_cmd} |grep "percona-xtrabackup-81" >"${log}" ; then
        echo "Uninstalling PXB 8.0 packages"
        ${remove_cmd} ${pxb81_packages} >>"${log}"
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

    if [[ "$1" = "pxb24" ]] && [[ "$2" = "main" ]]; then
        echo "Installing PXB 2.4 packages from the main repo"
        sudo percona-release enable-only tools release
        if [ -f /usr/bin/apt ]; then
            sudo apt-get update >>"${log}"
        fi

        if ! ${install_cmd} ${pxb24_packages} >>"${log}" ; then
            echo "ERR: PXB 2.4 packages could not be installed from the main repo"
            exit 1
        else
            echo "PXB 2.4 packages successfully installed with version: "
            xtrabackup --version
        fi
    elif [[ "$1" = "pxb24" ]] && [[ "$2" = "testing" ]]; then
        echo "Installing PXB 2.4 packages from the testing repo"
        sudo percona-release enable-only tools testing
        if [ -f /usr/bin/apt ]; then
            sudo apt-get update >>"${log}"
        fi

        if ! ${install_cmd} ${pxb24_packages} >>"${log}" ; then
            echo "ERR: PXB 2.4 packages could not be installed from the testing repo"
            exit 1
        else
            echo "PXB 2.4 packages successfully installed with version: "
            xtrabackup --version
        fi
    elif [[ "$1" = "pxb80" ]] && [[ "$2" = "main" ]]; then
        echo "Installing PXB 8.0 packages from the main repo"
        sudo percona-release enable-only tools release
        if [ -f /usr/bin/apt ]; then
            sudo apt-get update >>"${log}"
        fi

        if ! ${install_cmd} ${pxb80_packages} >>"${log}" ; then
            echo "ERR: PXB 8.0 packages could not be installed from the main repo"
            exit 1
        else
            echo "PXB 8.0 packages successfully installed with version: "
            xtrabackup --version
        fi
    elif [[ "$1" = "pxb80" ]] && [[ "$2" = "testing" ]]; then
        echo "Installing PXB 8.0 packages from the testing repo"
        sudo percona-release enable-only tools testing
        if [ -f /usr/bin/apt ]; then
            sudo apt-get update >>"${log}"
        fi

        if ! ${install_cmd} ${pxb80_packages} >>"${log}" ; then
            echo "ERR: PXB 8.0 packages could not be installed from the testing repo"
            exit 1
        else
            echo "PXB 8.0 packages successfully installed with version: "
            xtrabackup --version
        fi
    elif [[ "$1" = "pxb81" ]] && [[ "$2" = "main" ]]; then
        echo "Installing PXB 8.1 packages from the main repo"
        sudo percona-release enable-only tools release
        if [ -f /usr/bin/apt ]; then
            sudo apt-get update >>"${log}"
        fi

        if ! ${install_cmd} ${pxb81_packages} >>"${log}" ; then
            echo "ERR: PXB 8.1 packages could not be installed from the main repo"
            exit 1
        else
            echo "PXB 8.1 packages successfully installed with version: "
            xtrabackup --version
        fi
    elif [[ "$1" = "pxb81" ]] && [[ "$2" = "testing" ]]; then
        echo "Installing PXB 8.1 packages from the testing repo"
        sudo percona-release enable-only tools testing
        if [ -f /usr/bin/apt ]; then
            sudo apt-get update >>"${log}"
        fi

        if ! ${install_cmd} ${pxb81_packages} >>"${log}" ; then
            echo "ERR: PXB 8.1 packages could not be installed from the testing repo"
            exit 1
        else
            echo "PXB 8.1 packages successfully installed with version: "
            xtrabackup --version
        fi
    fi

}

install_pxb_package "${pxb_version}" "${repo}"
