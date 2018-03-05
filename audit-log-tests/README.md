#Audit Log Plugin tests will be here

## To build and start PS then to run tests please do
Go to any empty folder and run following:

```
$ clone=1 tap=0 bash ~/percona-qa/audit-log-tests/audit-testsuite.sh
```
It will clone percona-qa and PS from repo will build PS and start running the tests

## To run tests without building

```
$ clone=0 tap=0 bash ~/percona-qa/audit-log-tests/audit-testsuite.sh
```

## The result of sample run(will be updated):

```
$ clone=0 tap=0 bash ~/percona-qa/audit-log-tests/audit-testsuite.sh
Skipping Clone and Build
Running startup.sh from percona-qa
Adding scripts: start | start_group_replication | start_valgrind | start_gypsy | repl_setup | stop | kill | setup | cl | test | init | wipe | all | prepare | run | measure | gdb | myrocks_tokudb_init
Setting up server with default directories
2018-03-05T11:03:26.618825Z 0 [Warning] TIMESTAMP with implicit DEFAULT value is deprecated. Please use --explicit_defaults_for_timestamp server option (see documentation for more details).
2018-03-05T11:03:27.964685Z 0 [Warning] InnoDB: New log files created, LSN=45790
2018-03-05T11:03:28.310128Z 0 [Warning] InnoDB: Creating foreign key constraint system tables.
2018-03-05T11:03:28.509680Z 0 [Warning] No existing UUID has been found, so we assume that this is the first time that this server has been started. Generating a new UUID: d579047f-2064-11e8-b145-002590e9b448.
2018-03-05T11:03:28.540728Z 0 [Warning] Gtid table is not ready to be used. Table 'mysql.gtid_executed' cannot be opened.
2018-03-05T11:03:28.952966Z 0 [Warning] CA certificate ca.pem is self signed.
2018-03-05T11:03:29.034689Z 1 [Warning] root@localhost is created with an empty password ! Please consider switching off the --initialize-insecure option.
Enabling additional TokuDB/ROCKSDB engine plugin items if exists
Server socket: /home/shahriyar.rzaev/AUDIT_LOG_TESTS/PS280218-percona-server-5.7.21-20-linux-x86_64-debug/socket.sock with datadir: /home/shahriyar.rzaev/AUDIT_LOG_TESTS/PS280218-percona-server-5.7.21-20-linux-x86_64-debug/data
Server on socket /home/shahriyar.rzaev/AUDIT_LOG_TESTS/PS280218-percona-server-5.7.21-20-linux-x86_64-debug/socket.sock with datadir /home/shahriyar.rzaev/AUDIT_LOG_TESTS/PS280218-percona-server-5.7.21-20-linux-x86_64-debug/data halted
Done! To get a fresh instance at any time, execute: ./all (executes: stop;wipe;start;cl)
Starting Server!
Server socket: /home/shahriyar.rzaev/AUDIT_LOG_TESTS/PS280218-percona-server-5.7.21-20-linux-x86_64-debug/socket.sock with datadir: /home/shahriyar.rzaev/AUDIT_LOG_TESTS/PS280218-percona-server-5.7.21-20-linux-x86_64-debug/data
Installing the plugin
 ✓ Checking plugin installation result

1 test, 0 failures
 ✓ running test for audit_log_include_commands='create_db'
 ✓ running test for audit_log_include_commands='create_table'

2 tests, 0 failures
 ✓ running test for audit_log_include_databases='dummy_db'

1 test, 0 failures
```
