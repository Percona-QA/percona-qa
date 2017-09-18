#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

DIRNAME=$BATS_TEST_DIRNAME

@test "Running test_check_if_collection_exists" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_check_if_collection_exists
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_check_collection_count" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_check_collection_count
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_alter_table_engine_raises" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_alter_table_engine_raises
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_alter_table_drop_column" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_alter_table_drop_column
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_alter_table_engine" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_alter_table_engine
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_check_if_table_exists" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_check_if_table_exists
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_check_table_count" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_check_table_count
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_check_table_name" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_check_table_name
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_check_schema_name" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_check_schema_name
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_check_if_table_is_view" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_check_if_table_is_view
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_create_view_from_collection" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_create_view_from_collection
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_select_from_table [Should not raise an OperationalError after MYR-151/152]" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_select_from_table
  echo $output
  [ $status -eq 0 ]
}

@test "Running test_select_from_view [Should not raise an OperationalError asfter MYR-151/152]" {
  run python -m pytest -vv ${DIRNAME}/myrocks_mysqlx_plugin_test/test_module01.py::TestXPlugin::test_select_from_view
  echo $output
  [ $status -eq 0 ]
}
