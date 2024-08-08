#!/bin/bash

############################################################################################
# Created By Manish Chawla, Percona LLC                                                    #
# Modified By Mohit Joshi, Percona LLC                                                     #
# This script installs pxb24/pxb80/pxb8x-innovation from the main/testing repo             #
############################################################################################

log="$HOME/install_log"

help() {
    echo "Usage: $0 repo_name repo_type [version]"
    echo "Accepted values for repo_name: pxb-24 , pxb-80 , pxb-8x-innovation, pxb-84-lts"
    echo "Accepted values for repo_type: main, testing, experimental"
    echo "Accepted value for version: 81, 82, 83 [Required only when repo_name=pxb-8x-innovation]"
    echo "eg. pkg_install_tests.sh pxb-8x-innovation main 81"
    echo "eg. pkg_install_tests.sh pxb80 testing"
    echo "eg. pkg_install_tests.sh pxb24 main"
    echo "eg. pkg_install_test.sh pxb-84-lts testing"
    exit 1
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    help
fi

repo_name="$1"
repo_type="$2"

# Check if pxb_version is "pxb-8x-innovation"
if [ "$repo_name" == "pxb-8x-innovation" ]; then
    # Check if the number of arguments is 3
    if [ "$#" -ne 3 ]; then
        echo "Error: 'version' argument is required for pxb-8x-innovation. Accepted values: 81, 82, 83"
        help
    fi
    version=$3
else
    version=""  # Set version to an empty string for other cases
fi

if [ -f /usr/bin/yum ]; then
    install_cmd="sudo yum install -y"
    remove_cmd="sudo yum remove -y"
    list_cmd="sudo yum list installed"
    if [ "$repo_name" = "pxb-24" ]; then
        pxb_package="percona-xtrabackup-24"
        pxb_addon_packages="percona-xtrabackup-test-24 percona-xtrabackup-24-debuginfo"
    elif [ "$repo_name" = "pxb-80" ]; then
        pxb_package="percona-xtrabackup-80"
        pxb_addon_packages="percona-xtrabackup-test-80 percona-xtrabackup-80-debuginfo"
    elif [ "$repo_name" = "pxb-8x-innovation" ]; then
        pxb_package="percona-xtrabackup-$version"
        pxb_addon_packages="percona-xtrabackup-test-$version percona-xtrabackup-$version-debuginfo"
    elif [ "$repo_name" = "pxb-84-lts" ]; then
        pxb_package="percona-xtrabackup-84"
        pxb_addon_packages="percona-xtrabackup-test-84 percona-xtrabackup-84-debuginfo"
    else
        echo "Invalid pxb repo $repo_name"
        help
    fi
else
    install_cmd="sudo apt-get install -y"
    remove_cmd="sudo apt-get remove -y"
    list_cmd="sudo apt list --installed"
    if [ "$repo_name" = "pxb-24" ]; then
        pxb_package="percona-xtrabackup-24"
        pxb_addon_packages="percona-xtrabackup-test-24 percona-xtrabackup-dbg-24"
    elif [ "$repo_name" = "pxb-80" ]; then
        pxb_package="percona-xtrabackup-80"
        pxb_addon_packages="percona-xtrabackup-test-80 percona-xtrabackup-dbg-80"
    elif [ "$repo_name" = "pxb-8x-innovation" ]; then
        pxb_package="percona-xtrabackup-$version"
        pxb_addon_packages="percona-xtrabackup-test-$version percona-xtrabackup-dbg-$version"
    elif [ "$repo_name" = "pxb-84-lts" ]; then
        pxb_package="percona-xtrabackup-84"
        pxb_addon_packages="percona-xtrabackup-test-84 percona-xtrabackup-dbg-84"
    else
        echo "Invalid pxb repo $repo_name"
        help
    fi
fi

install_pxb_package() {
    echo "Checking if percona-xtrabackup is already installed" 
    if ${list_cmd} | grep "$pxb_package" >"${log}" ; then
        echo "Uninstalling $repo_name $version packages"
        ${remove_cmd} ${pxb_package} >>"${log}" 2>&1
        ${remove_cmd} ${pxb_addon_packages} >>"${log}" 2>&1
    else
        echo "PXB packages are not installed"
    fi

    ${remove_cmd} percona-release >>"${log}" 2>&1

    if [ -f /usr/bin/apt ]; then
        sudo apt-get update > /dev/null 2>&1
        wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb > /dev/null 2>&1
        sudo dpkg -i percona-release_latest.generic_all.deb > /dev/null 2>&1 
    else
        ${install_cmd} https://repo.percona.com/yum/percona-release-latest.noarch.rpm  > /dev/null  2>&1
    fi

    echo "Installing $repo_name $version packages from the $repo_type repo"
    sudo percona-release enable-only $repo_name $repo_type
    if [ -f /usr/bin/apt ]; then
        sudo apt-get update > /dev/null 2>&1
    fi

    if ! ${install_cmd} ${pxb_package} >>"${log}" ; then
        echo "ERR: $repo_name $version packages could not be installed from the $repo_type repo"
        exit 1
    else
        ${install_cmd} ${pxb_addon_packages}
        echo "$repo_name $version packages successfully installed with version: "
        xtrabackup --version
    fi
}

install_pxb_package
