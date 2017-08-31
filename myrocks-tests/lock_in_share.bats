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

@test "Running test_insert_dummy_data_into_table" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_insert_dummy_data_into_table
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_run_lock_in_share_select" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_run_lock_in_share_select
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_run_update_statement[Should ignore lock in share mode]" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_run_update_statement
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_run_for_update[FOR UPDATE]" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_run_for_update
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_run_for_update2[FOR UPDATE][Should raise an Errpr]" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_run_for_update2
  echo $output
  [ $status -eq 0 ]
}
