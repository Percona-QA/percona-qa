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

@test "Running test_run_lock_in_share_select[Should raise OperationalError, GAP locks detection]" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_run_lock_in_share_select_gap_lock
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_run_update_statement[Should raise OperationalError, GAP locks detection]" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_run_update_statement_gap_lock
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_run_for_update[FOR UPDATE][Should raise OperationalError, GAP locks detection]" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_run_for_update_gap_lock
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_run_for_update2[FOR UPDATE][Should raise OperationalError, GAP locks detection]" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_run_for_update2_gap_lock
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_run_alter_add_primary_key" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_run_alter_add_primary_key
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_run_update_statement[Should raise an OperationalError; Lock wait timeout exceeded]" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_run_update_statement
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_run_for_update2[FOR UPDATE][Should raise an OperationalError; Lock wait timeout exceeded]" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module03.py::TestLocks::test_run_for_update2
  echo $output
  [ $status -eq 0 ]
}
