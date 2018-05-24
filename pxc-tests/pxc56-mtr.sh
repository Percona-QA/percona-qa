#!/bin/bash

# This script is designed to run from Jenkins
# with 3 artifacts placed in the current working directory
#
# 1) Project Name: build-xtradb-cluster-binaries-56/label_exp=$Host,BUILD_TYPE=$Ttype
#    Artifact to copy: target/Percona-XtraDB-Cluster-*.tar.gz
# 2) Project Name: percona-xtrabackup-2.2-binaries/label_exp=$Host
#    Artifact to copy:
# 3) Project Name: qpress-binaries/label_exp=$Host
#    Artifact to copy: qpress

# Author: David Bennett - david.bennett at percona.com - 2015-06-01

# We start in the directory where our artifacts are copied

ROOT_FS=$(pwd)

# libeatmydata is a small LD_PRELOAD library designed
# to (transparently) disable fsync

if test -f /usr/local/lib/libeatmydata.so
then
  export LD_PRELOAD=/usr/local/lib/libeatmydata.so
elif test -f /usr/lib/libeatmydata.so
then
  export LD_PRELOAD=/usr/lib/libeatmydata.so
fi

# Make a build working directory and enter it

mkdir -p ${BUILD_NUMBER}
cd ${BUILD_NUMBER}

# Get our artifact filenames

PXC_TAR=$(find ${ROOT_FS} -maxdepth 1 -type f -name 'Percona-XtraDB-Cluster-*.tar.gz' | sort | tail -n1)
PXB_TAR=$(find ${ROOT_FS} -maxdepth 1 -type f -name 'percona-xtrabackup-*.tar.gz' | sort | tail -n1)
QPRESS_BIN=${ROOT_FS}/qpress

# Make sure we have what we need

if [ ! -f "${PXC_TAR}" ]; then
  echo "Percona XtraDB Cluster tarball not found!"
  exit 1
fi

if [ ! -f "${PXB_TAR}" ]; then
  echo "Percona XtraBackup tarball not found!"
  exit 1
fi

if [ ! -f "${QPRESS_BIN}" ]; then
  echo "qpress binary not found"
  exit 1
fi

# untar PXC and PXB

tar xzf ${PXC_TAR}
tar xzf ${PXB_TAR}

# make qpress executable

chmod 755 ${ROOT_FS}/qpress

# get our base names

PXC_BASE=$(find "${ROOT_FS}/${BUILD_NUMBER}" -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-*' | sort | tail -n1)
PXB_BASE=$(find "${ROOT_FS}/${BUILD_NUMBER}" -maxdepth 1 -type d -name 'percona-xtrabackup-*' | sort | tail -n1)

# Add PXB and qpress binary to path

export PATH="${PXB_BASE}/bin:${ROOT_FS}:${PATH}"

# find galera lib and add to envirionment

export WSREP_PROVIDER=$(find ${PXC_BASE} -type f -name 'libgalera*.so' | head -n1)

# get the tests to run from the command line
# if they're not specified then run the galera suite

if [ "$#" == 0 ]; then
  MTR_TESTS="--suite=galera"
else
  MTR_TESTS="$*"
fi

if [[ -n ${SKIPEM:-} ]];then
    echo -e $SKIPEM > /tmp/skip.tests
else
    :>/tmp/skip.tests
fi

# Run the MTR tests

cd ${PXC_BASE}/mysql-test
perl ./mtr --force \
  --retry-failure=$RETRIES --nowarnings --skip-test-list=/tmp/skip.tests \
  --max-test-fail=0 ${MTR_TESTS} \
  2>&1 | tee mtr.out; \
  MTR_EXIT_CODE=${PIPESTATUS[0]};

# build junit.xml from MTR output using awk script
# lifted from percona-server-5.6-TokuDB-MTR job

cat mtr.out | awk -f <(cat - <<-EOD
# header
BEGIN {
  print "<testsuite name=\"Percona XtraDB Cluster 56 - ${MTR_TESTS}\">"
  inFail = 0;
}

# if we are in failure and a result is found  then end exit
inFail == 1 && /^([[:alnum:]]+).*[\[] [a-z]+ [\]](.*)/ {
  print "]]>"
  print "    </system-out>"
  print "  </testcase>"
  inFail = 0
}


# report passing tests
/^([[:alnum:]]+).*[\[] (retry-)?pass [\]](.*)/ {
  print "  <testcase name=\""\$1"\" time=\"" \$NF/1000 "\">"
  print "    <system-out>"
  print "<![CDATA["
  print
  print "]]>"
  print "    </system-out>"
  print "  </testcase>"
}

# report disabled tests
/^(.*) .*\[ disabled \]/ {
  print "  <testcase name=\""\$1"\"><skipped/>"
  print "    <system-out>"
  print "<![CDATA["
  print
  print "]]>"
  print "    </system-out>"
  print "  </testcase>"
}

# report skipped tests
 /^(.*) .*\[ skipped \]/ {
  print "  <testcase name=\""\$1"\"><skipped/>"
  print "    <system-out>"
  print "<![CDATA["
  print
  print "]]>"
  print "    </system-out>"
  print "  </testcase>"
 }

# report failing tests
/^(.*) .*\[ (retry-)?fail \]/ {
  print "  <testcase name=\""\$1"\">"
  print "    <failure/>"
  print "    <system-out>"
  print "<![CDATA["
  inFail = 1
}

# print the body of the failure
inFail == 1 {
  print
}

# footer
END {
  # end the failure if we are still in it
  if (inFail == 1) {
    print "]]>"
    print "    </system-out>"
    print "  </testcase>"
  }
  print "</testsuite>"
}
EOD
) > junit.xml

# bundle results

find var/ -type f -regextype posix-egrep \( \
    -not -regex '.*\/install\.db\/.*' \
    -and -not -regex '.*\/std_data\/.*' \
    -and -not -name 'ib_log*' \
    -and -not -name 'ibdata*' \
    -and -not -iregex '.*\.((frm)|(myd)|(myi)|(dat)|(ibd)|(0)|(cs)|(index)|(cache)).*' \
  \) \
  | tar czf ${ROOT_FS}/results-${BUILD_NUMBER}.tar.gz -T -

# exit with status code from MTR

exit ${MTR_EXIT_CODE}

