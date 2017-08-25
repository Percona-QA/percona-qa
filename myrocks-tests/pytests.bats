#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

DIRNAME=$BATS_TEST_DIRNAME

@test "Running test_check_if_collection_exists" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_check_if_collection_exists
  echo $output
  [ $status -eq 0 ]
}
