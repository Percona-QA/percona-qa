# Welcome to MyRocks testing land

These tests are designed to run against MyRocks tables.
  > Script should be run from any folder outside of repo!

The project structure:

```
myrocks-testsuite.sh        -> Main bash file.
generated_columns.bats      -> Testing generated columns.
json.bats                   -> Testing json things here.
myrocks_mysqlx_plugin.py    -> Testing Python X Plugin with MyRocks here.
```

Sample run:

* If clone == 1 then script is going to clone from repo and build.
* If tap==1 then script is going to execute bats in tap mode.

```
[shahriyar.rzaev@qaserver-02 MYROCKS]$ clone=0 tap=1 bash ~/percona-qa/myrocks-tests/myrocks-testsuite.sh
Skipping Clone and Build
Running startup.sh from percona-qa
Adding scripts: start | start_group_replication | start_valgrind | start_gypsy | stop | kill | setup | cl | test | init | wipe | all | prepare | run | measure | myrocks_tokudb_init
Setting up server with default directories
2017-08-21T16:29:42.238159Z 0 [Warning] TIMESTAMP with implicit DEFAULT value is deprecated. Please use --explicit_defaults_for_timestamp server option (see documentation for more details).
2017-08-21T16:29:43.888857Z 0 [Warning] InnoDB: New log files created, LSN=45790
2017-08-21T16:29:44.355482Z 0 [Warning] InnoDB: Creating foreign key constraint system tables.
2017-08-21T16:29:44.613343Z 0 [Warning] No existing UUID has been found, so we assume that this is the first time that this server has been started. Generating a new UUID: f0c661c0-868d-11e7-88ac-002590e9b448.
2017-08-21T16:29:44.662139Z 0 [Warning] Gtid table is not ready to be used. Table 'mysql.gtid_executed' cannot be opened.
2017-08-21T16:29:45.172466Z 0 [Warning] CA certificate ca.pem is self signed.
2017-08-21T16:29:45.232271Z 1 [Warning] root@localhost is created with an empty password ! Please consider switching off the --initialize-insecure option.
Enabling additional TokuDB/ROCKSDB engine plugin items if exists
Server socket: /home/shahriyar.rzaev/MYROCKS/PS170817-percona-server-5.7.18-16-linux-x86_64-debug/socket.sock with datadir: /home/shahriyar.rzaev/MYROCKS/PS170817-percona-server-5.7.18-16-linux-x86_64-debug/data
Server on socket /home/shahriyar.rzaev/MYROCKS/PS170817-percona-server-5.7.18-16-linux-x86_64-debug/socket.sock with datadir /home/shahriyar.rzaev/MYROCKS/PS170817-percona-server-5.7.18-16-linux-x86_64-debug/data halted
Done! To get a fresh instance at any time, execute: ./all (executes: stop;wipe;start;sleep 5;cl)
Starting Server!
Server socket: /home/shahriyar.rzaev/MYROCKS/PS170817-percona-server-5.7.18-16-linux-x86_64-debug/socket.sock with datadir: /home/shahriyar.rzaev/MYROCKS/PS170817-percona-server-5.7.18-16-linux-x86_64-debug/data
Creating sample database
Creating sample table
Altering table engine
Running generated_columns.bats
1..3
ok 1 Adding virtual generated json type column
ok 2 Adding stored generated json type column
ok 3 Adding stored generated varchar type column
Running json.bats
1..1
ok 1 Adding json column
Installing mysql-connector-python
Already Installed
Installing mysqlx plugin
Creating sample user
Granting sample user
Running X Plugin test
Creating collection
Checking assert(True == collection.exists_in_database())
Inserting 3 rows into collection
Checking assert(3 == collection.count())
Altering default collection engine from InnoDB to MyRocks [Should raise an OperationalError]
'Specified storage engine' is not supported for generated columns.
```
