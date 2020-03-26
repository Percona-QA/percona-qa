#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

if [ "" == "$2" ]; then
  build_option=0
else
  build_option=$2
fi

build_check(){
  if [ $build_option -eq 0 ];then
    echo "No option was specified, so retrieving all builds: opt/dbg/val. To retrieve only one of these use option as follows: 1 (opt), 2 (dbg), 3 (val)"
    BUILDS=0
  elif [ $build_option -eq 1 ]; then
    echo "Only retrieving opt build, as 1 was specified as option to this script (1=retrieve optimized build only)"
    BUILDS=1
  elif [ $build_option -eq 2 ]; then
    echo "Only retrieving dbg build, as 2 was specified as option to this script (2=retrieve debug build only)"
    BUILDS=2
  elif [ $build_option -eq 3 ]; then
    echo "Only retrieving val build, as 3 was specified as option to this script (3=retrieve valgrind build only)"
    BUILDS=3
  else
    echo "Assert: an invalid option ('$build_option') was passed to this script. Terminating."
    echo "Syntax: to retrieve all builds, opt/dbg/val, specify no option. To retrieve only one of these use option as follows: 1 (opt), 2 (dbg), 3 (val)";
    exit 1
  fi
}

if [ -d ./archive ]; then
  echo "A directory ./archive exists here. Please delete it, rename it or move it out of this directory so that this script can continue."
  exit 1
elif [ "" != "$3" ]; then
  echo "Assert: Three options were specified to the script, it only accepts and handles two. Terminating."
  exit 1
elif [ "" == "$1" ]; then
  echo "Assert: This script expects two parameters:"
  echo "./get_percona.sh {55 or 56} {no_option or 1 or 2 or 3}"
  echo "Example: "./get_percona.sh 56" will retrieve all builds (opt,dbg,val) for Percona Server 5.6"
  echo "To retrieve only a specific build, set the second option as follows: 1 (opt), 2 (dbg), 3 (val)"
  exit 1
elif [ 55 -eq $1 ]; then
  VERSION=55;
  build_check
elif [ 56 -eq $1 ]; then
  VERSION=56;
  build_check
else
  echo "Assert: an invalid option ('$1') was passed to this script. Terminating."
  echo "Syntax: to retrieve PS version as follows. 55 (for PS-5.5..) 56 (for PS-5.6)";
  exit 1
fi

unpack(){
  unzip ./archive.zip
  if [ $VERSION -eq 55 ]; then
    ls ./archive/target/*.tar.gz | xargs -I_ tar -xf _
  elif [ $VERSION -eq 56 ]; then
    ls ./archive/*.tar.gz | xargs -I_ tar -xf _
  fi
  rm -Rf archive*
}

if [ $VERSION -eq 55 ]; then
  if [ $BUILDS -eq 0 -o $BUILDS -eq 1 ]; then
    wget http://jenkins.percona.com/view/QA/job/percona-server-5.5-nightly-optimized-binaries/label_exp=centos6-64/lastSuccessfulBuild/artifact/*zip*/archive.zip
    unpack
  fi
  if [ $BUILDS -eq 0 -o $BUILDS -eq 2 ]; then
    wget http://jenkins.percona.com/view/QA/job/percona-server-5.5-nightly-debug-binaries/label_exp=centos6-64/lastSuccessfulBuild/artifact/*zip*/archive.zip
    unpack
  fi
  if [ $BUILDS -eq 0 -o $BUILDS -eq 3 ]; then
    wget http://jenkins.percona.com/view/QA/job/percona-server-5.5-nightly-valgrind-binaries/label_exp=centos6-64/lastSuccessfulBuild/artifact/*zip*/archive.zip
    unpack
  fi
elif [ $VERSION -eq 56 ]; then
  if [ $BUILDS -eq 0 -o $BUILDS -eq 1 ]; then
    wget http://jenkins.percona.com/view/QA/job/percona-server-5.6-binaries-opt-yassl/label_exp=centos6-64/lastSuccessfulBuild/artifact/*zip*/archive.zip
    unpack
  fi
  if [ $BUILDS -eq 0 -o $BUILDS -eq 2 ]; then
    wget http://jenkins.percona.com/view/QA/job/percona-server-5.6-binaries-debug-yassl/label_exp=centos6-64/lastSuccessfulBuild/artifact/*zip*/archive.zip
    unpack
  fi
  if [ $BUILDS -eq 0 -o $BUILDS -eq 3 ]; then
    wget http://jenkins.percona.com/view/QA/job/percona-server-5.6-binaries-valgrind-yassl/label_exp=centos6-64/lastSuccessfulBuild/artifact/*zip*/archive.zip
    unpack
  fi
fi
echo "Done! Build(s) are available in ${PWD}"

