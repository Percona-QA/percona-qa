#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

# MySQL X Shell tests

DIRNAME=$BATS_TEST_DIRNAME

@test "Running mysqlsh_db_get_collections" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module02.py::TestMySQLShell::test_mysqlsh_db_get_collections
  echo $output
  [ $status -eq 0 ]
}
