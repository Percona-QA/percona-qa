#!/bin/bash

set -e

dnf -y install dnf-plugins-core
dnf config-manager --set-enabled codeready-builder-for-rhel-9-rhui-rpms
dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

DEPS=(
    clang
    zlib-devel
    readline-devel
    gcc
    lz4
    lz4-devel
    python3
    krb5-devel
    openssl-devel
    pam-devel
    libxml2-devel
    libxslt-devel
    openldap-devel
    libuuid-devel
    systemd-devel
    tcl-devel
    python3-devel
    libicu-devel
    libzstd
    libzstd-devel
    llvm
    llvm-toolset
    llvm-devel
    clang-devel
    vim
    git
    perl-ExtUtils*
    docbook-xsl
    perl-Test-Simple
    perl-CPAN
    libcurl-devel
    perl-App-cpanminus
    perl-IPC-Run
    perl-Text-Trim
    make
    autoconf
    json-c-devel
    python3-pip
    wget
    unzip
    lsof
    perl-LWP-Protocol-https
    perl-JSON
    jq
    liburing
    liburing-devel
)

sudo dnf update -y
sudo dnf install -y ${DEPS[@]}
sudo dnf -y groupinstall "Development tools"
sudo dnf install -y clang-devel clang