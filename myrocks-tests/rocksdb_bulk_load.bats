DIRNAME=$BATS_TEST_DIRNAME

@test "Running test_alter_table_engine_bulk" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module04.py::TestBulk::test_alter_table_engine_bulk
  echo $output
  [ $status -eq 0 ]
}
