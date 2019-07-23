set -eu

source ${SCRIPT_PWD}/inc/config.sh
source ${SCRIPT_PWD}/inc/pbm.sh

function vlog
{
    echo "`date +"%F %T"`: `basename "$0"`: ##### $@ #####" >&2
}

########################################################################
# Remove server var* directories from the worker's var root
########################################################################

function remove_var_dirs()
{
    rm -rf ${TEST_VAR_ROOT}/var[0-9]
}

function die()
{
  vlog "$*" >&2
  exit 1
}

function run_cmd()
{
  vlog "===> $@"
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -ne 0 ]
  then
      die "===> `basename $1` failed with exit code $rc"
  fi
}

function run_cmd_expect_failure()
{
  vlog "===> $@"
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -eq 0 ]
  then
      die "===> `basename $1` succeeded when it was expected to fail"
  fi
}

########################################################################
# Workarounds for a bug in grep 2.10 when grep -q file > file would
# result in a failure.
########################################################################
function grep()
{
    command grep "$@" | cat
    return ${PIPESTATUS[0]}
}

function egrep()
{
    command egrep "$@" | cat
    return ${PIPESTATUS[0]}
}

########################################################################
# Skip the current test with a given comment
########################################################################
function skip_test()
{
    echo $1 > $SKIPPED_REASON
    exit $SKIPPED_EXIT_CODE
}
