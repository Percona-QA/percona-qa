# Created by Shahriyar Rzayev from Percona

# BATS file for running LOCK IN SHARE MODE tests

DIRNAME=$BATS_TEST_DIRNAME

@test "Running test_create_schema" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_create_schema
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_create_table" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_create_table
  echo $output
  [ $status -eq 0 ]
}
