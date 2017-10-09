# Welcome to MyRocks testing land

These tests are designed to run against MyRocks tables.
  > Script should be run from any empty folder outside of repo!

The project structure:

```
load_data_infile                                -> The folder for load_data_infile tests
myrocks_mysqlx_plugin/myrocks_mysqlx_plugin.py  -> The main Python working code for X Plugin tests.
myrocks_mysqlx_plugin_test/test_module01.py     -> PyTest unit tests for myrocks_mysqlx_plugin.py.
myrocks_mysqlx_plugin/myrocks_mysqlsh.py        -> The main Python working code for MySQL XShell tests.  
myrocks_mysqlx_plugin_test/test_module02.py     -> Pytest unit tests for myrocks_mysqlsh.py.
myrocks_mysqlx_plugin/lock_in_share_mode.py     -> The main Python working code for Lock in share mode etc. tests.
myrocks_mysqlx_plugin_test/test_module03.py     -> Pytest unit tests for lock_in_share_mode.py.
myrocks_mysqlx_plugin/rocksdb_bulk_load.py      -> The main Python working code for Rocksdb Bulk Load
myrocks_mysqlx_plugin_test/test_module03.py     -> Pytest unit tests for rocksdb_bulk_load.py
myrocks-testsuite.sh                            -> Main bash file.
generated_columns.bats                          -> Testing generated columns.
json.bats                                       -> Testing json things here.
x_plugin.bats                                     -> The bats run for calling Pytest tests for X Plugin.
mysqlsh.bats                                    -> The bats run for calling Pytest tests for MySQL XShell.
lock_in_share.bats                              -> The bats run for calling Pytest tests for Lock in share mode etc.
rocksdb_bulk_load.bats                          -> The bats run for calling Pytests tests for Rocksdb Bulk Load.
mysqldump.bats                                  -> The bats run for running mysqldump tests.
proxysql.bats                                   -> The bats run for ProxySQL tests.
```

Sample run:

* If clone == 1 then script is going to clone from repo and build.
* If tap==1 then script is going to execute bats in tap mode.

```
$ clone=0 tap=0 bash ~/percona-qa/myrocks-tests/myrocks-testsuite.sh
Skipping Clone and Build
Running startup.sh from percona-qa
Adding scripts: start | start_group_replication | start_valgrind | start_gypsy | stop | kill | setup | cl | test | init | wipe | all | prepare | run | measure | myrocks_tokudb_init
Setting up server with default directories
2017-10-09T09:07:30.882155Z 0 [Warning] TIMESTAMP with implicit DEFAULT value is deprecated. Please use --explicit_defaults_for_timestamp server option (see documentation for more details).
2017-10-09T09:07:32.584524Z 0 [Warning] InnoDB: New log files created, LSN=45790
2017-10-09T09:07:32.988717Z 0 [Warning] InnoDB: Creating foreign key constraint system tables.
2017-10-09T09:07:33.199587Z 0 [Warning] No existing UUID has been found, so we assume that this is the first time that this server has been started. Generating a new UUID: 490fabb9-acd1-11e7-8162-002590e9b448.
2017-10-09T09:07:33.259670Z 0 [Warning] Gtid table is not ready to be used. Table 'mysql.gtid_executed' cannot be opened.
2017-10-09T09:07:33.575199Z 0 [Warning] CA certificate ca.pem is self signed.
2017-10-09T09:07:33.700423Z 1 [Warning] root@localhost is created with an empty password ! Please consider switching off the --initialize-insecure option.
Enabling additional TokuDB/ROCKSDB engine plugin items if exists
Server socket: /home/shahriyar.rzaev/MYROCKS/PS180917-percona-server-5.7.19-17-linux-x86_64-debug/socket.sock with datadir: /home/shahriyar.rzaev/MYROCKS/PS180917-percona-server-5.7.19-17-linux-x86_64-debug/data
Server on socket /home/shahriyar.rzaev/MYROCKS/PS180917-percona-server-5.7.19-17-linux-x86_64-debug/socket.sock with datadir /home/shahriyar.rzaev/MYROCKS/PS180917-percona-server-5.7.19-17-linux-x86_64-debug/data halted
Done! To get a fresh instance at any time, execute: ./all (executes: stop;wipe;start;sleep 5;cl)
Starting Server!
Server socket: /home/shahriyar.rzaev/MYROCKS/PS180917-percona-server-5.7.19-17-linux-x86_64-debug/socket.sock with datadir: /home/shahriyar.rzaev/MYROCKS/PS180917-percona-server-5.7.19-17-linux-x86_64-debug/data
Creating sample database
Creating sample table
Altering table engine
Running generated_columns.bats
 ✓ Adding virtual generated json type column
 ✓ Adding stored generated json type column
 ✓ Adding stored generated varchar type column

3 tests, 0 failures
Running json.bats
 ✓ Adding json column

1 test, 0 failures
Installing mysql-connector-python
Already Installed
Installing mysql-shell
Already Installed
Installing mysqlx plugin
Creating sample user
Granting sample user
#Running X Plugin tests#
 ✓ Running test_check_if_collection_exists
 ✓ Running test_check_collection_count
 ✓ Running test_alter_table_engine_raises
 ✓ Running test_alter_table_drop_column
 ✓ Running test_alter_table_engine
 ✓ Running test_check_if_table_exists
 ✓ Running test_check_table_count
 ✓ Running test_check_table_name
 ✓ Running test_check_schema_name
 ✓ Running test_check_if_table_is_view
 ✓ Running test_create_view_from_collection
 ✓ Running test_select_from_table [Should not raise an OperationalError after MYR-151/152]
 ✓ Running test_select_from_view [Should not raise an OperationalError asfter MYR-151/152]

13 tests, 0 failures
#Running mysqlsh tests#
 ✓ Running mysqlsh_db_get_collections

1 test, 0 failures
#Running lock in share mode, Gap locks detection etc. tests#
 ✓ Running test_create_schema
 ✓ Running test_create_table
 ✓ Running test_insert_dummy_data_into_table
 ✓ Running test_run_lock_in_share_select[Should raise OperationalError, GAP locks detection]
 ✓ Running test_run_update_statement[Should raise OperationalError, GAP locks detection]
 ✓ Running test_run_for_update[FOR UPDATE][Should raise OperationalError, GAP locks detection]
 ✓ Running test_run_for_update2[FOR UPDATE][Should raise OperationalError, GAP locks detection]
 ✓ Running test_run_alter_add_primary_key
 ✓ Running test_run_update_statement[Should raise an OperationalError; Lock wait timeout exceeded]
 ✓ Running test_run_for_update2[FOR UPDATE][Should raise an OperationalError; Lock wait timeout exceeded]

10 tests, 0 failures
Getting sample test db repo
fatal: destination path 'test_db' already exists and is not an empty directory.
Importing sample test db
INFO
CREATING DATABASE STRUCTURE
INFO
storage engine: InnoDB
INFO
LOADING departments
INFO
LOADING employees
INFO
LOADING dept_emp
INFO
LOADING dept_manager
INFO
LOADING titles
INFO
LOADING salaries
data_load_time_diff
00:05:50
#Running bulk load tests#
 ✓ Running test_alter_table_engine_bulk
 ✓ Running test_select_enabled_bulk_load
 ✓ Running test_select_disabled_bulk_load

3 tests, 0 failures
################################################################
Actions to test mysqldump
Altering employees.salaries engine to innodb
Running DROP TABLE IF EXISTS
Creating salaries1 from salaries
Creating salaries2 from salaries
Creating salaries3 from salaries
Altering engine employees.salaries2 to RocksDB
Altering engine employees.salaries3 to TokuDB
Inserting data to employees.salaries1
Inserting data to employees.salaries2
Inserting data to employees.salaries3
Taking backup using mysqldump without any option
Taking backup using mysqldump with --order-by-primary-desc=true
Importing dump2.sql here
Running mysqldump.bats
 ✓ Running test search rocksdb_enable_bulk_load variable in dump file
 ✓ Running test search disable_bulk_load variable in dump file
 ✓ Running test search ORDER BY clause in dump file
 ✓ Checking salaries1 row count
 ✓ Checking salaries2 row count
 ✓ Checking salaries3 row count

6 tests, 0 failures
################################################################
Starting ProxySQL tests
mysql: [Warning] Using a password on the command line interface can be insecure.
Starting independent PS node1..
mysql: [Warning] Using a password on the command line interface can be insecure.
mysql: [Warning] Using a password on the command line interface can be insecure.
mysql: [Warning] Using a password on the command line interface can be insecure.
You can use the following login credentials to connect Percona Server through ProxySQL
ProxySQL connection mysql --user=root --host=localhost --port=6033 --protocol=tcp
Creating test database over ProxySQL
Creating dummy RocksDB table over ProxySQL
Inserting dummy data into this table over ProxySQL
Running proxysql.bats
 ✓ Running select on PS1

1 test, 0 failures
################################################################
Starting LOAD_DATA_INFILE tests
Running load_data_infile.bats
 ✓ create initial tables
 ✓ load initial data
 ✓ check table checksum
 ✓ select into outfile
 ✓ check file diff

5 tests, 0 failures
```
