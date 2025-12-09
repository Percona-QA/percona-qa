#!/bin/bash

set -euo pipefail

# Cleanup
old_server_cleanup
if [ -d $PGDATA ]; then rm -rf $PGDATA ; fi

echo "1=> Initialize Data directory"
initialize_server $PGDATA
enable_pg_tde $PGDATA

echo "2=> Start PG Server"
start_pg $PGDATA $PORT

echo "3=> Start OpenBao Server"
start_openbao_server

echo "4=> Start KMIP Server(pykmip)"
start_kmip_server

echo "############################################################################"
echo "# Scenario 1: Access Local Key Provider from Outside the scope of DB       #"
echo "############################################################################"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE db1"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE db2"
$INSTALL_DIR/bin/psql -d db1 -c"CREATE EXTENSION pg_tde"

$INSTALL_DIR/bin/psql -d db1 -c"SELECT pg_tde_add_database_key_provider_vault_v2('vault_keyring','$vault_url','$secret_mount_point', '$token_filepath', NULL,'pg_tde_ns1/');"
echo "Creating Principal key using local key provider. Must pass"
$INSTALL_DIR/bin/psql  -d db1 -c"SELECT pg_tde_create_key_using_database_key_provider('vault_key1','vault_keyring');"
$INSTALL_DIR/bin/psql  -d db1 -c"SELECT pg_tde_set_key_using_database_key_provider('vault_key1','vault_keyring');"


$INSTALL_DIR/bin/psql -d db2 -c"CREATE EXTENSION pg_tde;"
echo "Trying to create Principal Key using a key provider outside the scope of db2. Must fail"
$INSTALL_DIR/bin/psql -d db2 -c"SELECT pg_tde_create_key_using_database_key_provider('vault_key1','vault_keyring');"

$INSTALL_DIR/bin/psql  -d postgres -c"DROP DATABASE db2"

echo "#########################################################################"
echo "# Scenario 2: Multiple Databases with Different Key Providers           #"
echo "#########################################################################"
echo "Create 3 global providers using kmip, vault and file"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE EXTENSION pg_tde"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_vault_v2('vault_keyring2','$vault_url','$secret_mount_point', '$token_filepath', NULL, 'pg_tde_ns1/');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_kmip('kmip_keyring2','$kmip_server_address',$kmip_server_port,'$kmip_client_ca','$kmip_client_key','$kmip_server_ca');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_file('file_keyring2','$PGDATA/keyring.file');"

echo "Create 3 databases db1, db2, db3"
$INSTALL_DIR/bin/psql -d postgres -c"DROP DATABASE IF EXISTS db1"
$INSTALL_DIR/bin/psql -d postgres -c"DROP DATABASE IF EXISTS db2"
$INSTALL_DIR/bin/psql -d postgres -c"DROP DATABASE IF EXISTS db3"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE db1;"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE db2;"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE db3;"
$INSTALL_DIR/bin/psql -d db1 -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d db2 -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d db3 -c"CREATE EXTENSION pg_tde;"

echo "Set Principal Keys for db1, db2, db3"
$INSTALL_DIR/bin/psql -d db1 -c"SELECT pg_tde_create_key_using_global_key_provider('vault_key2','vault_keyring2');"
$INSTALL_DIR/bin/psql -d db1 -c"SELECT pg_tde_set_key_using_global_key_provider('vault_key2','vault_keyring2');"

$INSTALL_DIR/bin/psql -d db2 -c"SELECT pg_tde_create_key_using_global_key_provider('kmip_key2','kmip_keyring2');"
$INSTALL_DIR/bin/psql -d db2 -c"SELECT pg_tde_set_key_using_global_key_provider('kmip_key2','kmip_keyring2');"

$INSTALL_DIR/bin/psql -d db3 -c"SELECT pg_tde_create_key_using_global_key_provider('file_key2','file_keyring2');"
$INSTALL_DIR/bin/psql -d db3 -c"SELECT pg_tde_set_key_using_global_key_provider('file_key2','file_keyring2');"

echo "Create tables in db1, db2, db3"
$INSTALL_DIR/bin/psql -d db1 -c"CREATE TABLE t1(a INT) USING tde_heap;"
$INSTALL_DIR/bin/psql -d db2 -c"CREATE TABLE t2(a INT) USING tde_heap;"
$INSTALL_DIR/bin/psql -d db3 -c"CREATE TABLE t3(a INT) USING tde_heap;"
$INSTALL_DIR/bin/psql -d db1 -c"INSERT INTO t1 VALUES(100);"
$INSTALL_DIR/bin/psql -d db2 -c"INSERT INTO t2 VALUES(100);"
$INSTALL_DIR/bin/psql -d db3 -c"INSERT INTO t3 VALUES(100);"

$INSTALL_DIR/bin/psql -d db1 -c"SELECT * FROM t1"
$INSTALL_DIR/bin/psql -d db2 -c"SELECT * FROM t2"
$INSTALL_DIR/bin/psql -d db3 -c"SELECT * FROM t3"

restart_pg $PGDATA $PORT

$INSTALL_DIR/bin/psql -d db1 -c"SELECT * FROM t1"
$INSTALL_DIR/bin/psql -d db2 -c"SELECT * FROM t2"
$INSTALL_DIR/bin/psql -d db3 -c"SELECT * FROM t3"

echo "#############################################################"
echo "# Scenario 3: Testing Default Principal Key                 #"
echo "#############################################################"

echo "..Create 2 Datbases test1, test2"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE test1;"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE test2;"
$INSTALL_DIR/bin/psql -d test1 -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d test2 -c"CREATE EXTENSION pg_tde;"

echo "..Add a Local vault key provider for test1"
$INSTALL_DIR/bin/psql -d test1 -c"SELECT pg_tde_add_database_key_provider_vault_v2('vault_keyring3','$vault_url','$secret_mount_point','$token_filepath',NULL,'pg_tde_ns1/');"
echo "..Create a Principal key stored in vault for test1"
$INSTALL_DIR/bin/psql -d test1 -c"SELECT pg_tde_create_key_using_database_key_provider('vault_key3','vault_keyring3');"
$INSTALL_DIR/bin/psql -d test1 -c"SELECT pg_tde_set_key_using_database_key_provider('vault_key3','vault_keyring3');"

echo "..Add a Global Kmip key provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_kmip('kmip_keyring3','$kmip_server_address',$kmip_server_port,'$kmip_client_ca','$kmip_client_key','$kmip_server_ca');"

echo "..Create a Global Default Principal key stored in kmip"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('kmip_key3','kmip_keyring3');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_default_key_using_global_key_provider('kmip_key3','kmip_keyring3');"

echo "..Create encrypted table t1 in test1"
$INSTALL_DIR/bin/psql -d test1 -c"CREATE TABLE t1(a INT) USING tde_heap;"
$INSTALL_DIR/bin/psql -d test1 -c"INSERT INTO t1 VALUES(100);"

echo "..Create encrypted table t1 in test2"
$INSTALL_DIR/bin/psql -d test2 -c"CREATE TABLE t1(a INT) USING tde_heap;"
$INSTALL_DIR/bin/psql -d test2 -c"INSERT INTO t1 VALUES(1);"

echo "..Query tables from both test1, test2"
$INSTALL_DIR/bin/psql -d test1 -c"SELECT * FROM t1;"
$INSTALL_DIR/bin/psql -d test2 -c"SELECT * FROM t1;"

echo "..List all Key providers"
$INSTALL_DIR/bin/psql -d test1 -c"SELECT pg_tde_list_all_database_key_providers();"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_list_all_global_key_providers();"

echo "..Restart server"
restart_pg $PGDATA $PORT

echo "..Query tables from both test1, test2"
$INSTALL_DIR/bin/psql -d test1 -c"SELECT * FROM t1;"
$INSTALL_DIR/bin/psql -d test2 -c"SELECT * FROM t1;"

echo "..List all Key providers"
$INSTALL_DIR/bin/psql -d test1 -c"SELECT pg_tde_list_all_database_key_providers();"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_list_all_global_key_providers();"

$INSTALL_DIR/bin/psql -d test1 -c"DROP TABLE t1"
$INSTALL_DIR/bin/psql -d test2 -c"DROP TABLE t1"

echo "..Deleting all key providers and restarting server"
$INSTALL_DIR/bin/psql -d test1 -c"SELECT pg_tde_delete_key()"
$INSTALL_DIR/bin/psql -d test1 -c"SELECT pg_tde_delete_default_key()"
$INSTALL_DIR/bin/psql -d test1 -c"SELECT pg_tde_delete_database_key_provider('vault_keyring3')"
$INSTALL_DIR/bin/psql -d test1 -c"SELECT pg_tde_delete_global_key_provider('kmip_keyring3')"

echo "..Restart server"
restart_pg $PGDATA $PORT

echo "..Check all Key providers are deleted"
$INSTALL_DIR/bin/psql -d test1 -c"SELECT pg_tde_list_all_database_key_providers();"
$INSTALL_DIR/bin/psql -d test1 -c"SELECT pg_tde_list_all_global_key_providers();"


echo "#########################################################################"
echo "# Scenario 4: Testing Single Database with multiple Key Providers       #"
echo "#########################################################################"

echo "..Create Database sbtest2"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE sbtest2;"
$INSTALL_DIR/bin/psql -d sbtest2 -c"CREATE EXTENSION pg_tde;"

echo "..Add a local vault key provider for sbtest2"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_add_database_key_provider_vault_v2('vault_keyring4','$vault_url','$secret_mount_point', '$token_filepath', NULL, 'pg_tde_ns1/');"
echo "..Create a Principal key stored in vault for sbtest2"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_create_key_using_database_key_provider('vault_key4','vault_keyring4');"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_set_key_using_database_key_provider('vault_key4','vault_keyring4');"

echo "Fetch Principal Key Info"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_key_info();"
echo "..Verify Principal Key"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_verify_key();"

echo "..Create encrypted table t1 in sbtest2"
$INSTALL_DIR/bin/psql -d sbtest2 -c"CREATE TABLE t1(a INT, b varchar) USING tde_heap;"
$INSTALL_DIR/bin/psql -d sbtest2 -c"INSERT INTO t1 VALUES(100,'Mohit');"
$INSTALL_DIR/bin/psql -d sbtest2 -c"INSERT INTO t1 VALUES(200,'Rohit');"
$INSTALL_DIR/bin/psql -d sbtest2 -c"UPDATE t1 SET b='Sachin' WHERE a=100;"

echo "..Add a local kmip key provider for sbtest2"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_add_database_key_provider_kmip('kmip_keyring4','$kmip_server_address',$kmip_server_port,'$kmip_client_ca','$kmip_client_key','$kmip_server_ca');"
echo "..Create a Principal key stored in kmip for sbtest2"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_create_key_using_database_key_provider('kmip_key4','kmip_keyring4');"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_set_key_using_database_key_provider('kmip_key4','kmip_keyring4');"

echo "Fetch Principal Key Info"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_key_info();"
echo "..Verify Principal Key"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_verify_key();"

echo "..Create encrypted table t2 in sbtest2"
$INSTALL_DIR/bin/psql -d sbtest2 -c"CREATE TABLE t2(a INT, b varchar) USING tde_heap;"
$INSTALL_DIR/bin/psql -d sbtest2 -c"INSERT INTO t2 VALUES(100,'Mohit');"
$INSTALL_DIR/bin/psql -d sbtest2 -c"INSERT INTO t2 VALUES(200,'Rohit');"
$INSTALL_DIR/bin/psql -d sbtest2 -c"UPDATE t2 SET b='Sachin' WHERE a=100;"

echo "..Add a local file key provider for sbtest2"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_add_database_key_provider_file('file_keyring','$PGDATA/keyring.file');"
echo "..Create a Principal key stored in file for sbtest2"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_create_key_using_database_key_provider('file_key1','file_keyring');"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_set_key_using_database_key_provider('file_key1','file_keyring');"

echo "Fetch Principal Key Info"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_key_info();"
echo "..Verify Principal Key"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_verify_key();"

echo "..Create encrypted table t3 in sbtest2"
$INSTALL_DIR/bin/psql -d sbtest2 -c"CREATE TABLE t3(a INT, b varchar) USING tde_heap;"
$INSTALL_DIR/bin/psql -d sbtest2 -c"INSERT INTO t3 VALUES(100,'Mohit');"
$INSTALL_DIR/bin/psql -d sbtest2 -c"INSERT INTO t3 VALUES(200,'Rohit');"
$INSTALL_DIR/bin/psql -d sbtest2 -c"UPDATE t3 SET b='Sachin' WHERE a=100;"

echo "..List of all Local Key Providers"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT pg_tde_list_all_database_key_providers();"

echo "..Query tables t1, t2, t3"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT * FROM t1;"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT * FROM t2;"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT * FROM t3;"

restart_pg $PGDATA $PORT

echo "..Query table sbtest2.t1"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT * FROM t1;"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT * FROM t2;"
$INSTALL_DIR/bin/psql -d sbtest2 -c"SELECT * FROM t3;"
$INSTALL_DIR/bin/psql -d sbtest2 -c"DROP TABLE t1;"
$INSTALL_DIR/bin/psql -d sbtest2 -c"DROP TABLE t2;"
$INSTALL_DIR/bin/psql -d sbtest2 -c"DROP TABLE t3;"

echo "#############################################################"
echo "# Scenario 5: Global Key Provider Change and Data Integrity #"
echo "#############################################################"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE sbtest5"
$INSTALL_DIR/bin/psql -d sbtest5 -c"CREATE EXTENSION pg_tde"

echo ".. Add 3 Global Key Provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_file('file_keyring5','$PGDATA/keyring.file');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_kmip('kmip_keyring5','$kmip_server_address',$kmip_server_port,'$kmip_client_ca','$kmip_client_key','$kmip_server_ca');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_vault_v2('vault_keyring5','$vault_url','$secret_mount_point', '$token_filepath', NULL, 'pg_tde_ns1/');"
echo "..Create a Principal key stored in file for sbtest5"
$INSTALL_DIR/bin/psql -d sbtest5 -c"SELECT pg_tde_create_key_using_global_key_provider('file_key5','file_keyring5');"
$INSTALL_DIR/bin/psql -d sbtest5 -c"SELECT pg_tde_set_key_using_global_key_provider('file_key5','file_keyring5');"
echo "..Create table t1"
$INSTALL_DIR/bin/psql -d sbtest5 -c"CREATE TABLE t1(a INT, b varchar) USING tde_heap;"
$INSTALL_DIR/bin/psql -d sbtest5 -c"INSERT INTO t1 VALUES(100,'Mohit');"

echo "..Change Key provider configs"
echo "Must fail since current key does not exists in the new key provider file"
$INSTALL_DIR/bin/psql -d sbtest5 -c"SELECT pg_tde_change_global_key_provider_file('file_keyring5','$PGDATA/keyring_new.file');"
cp $PGDATA/keyring.file $data_dir/keyring_new.file
echo "Must be successful now"
$INSTALL_DIR/bin/psql -d sbtest5 -c"SELECT pg_tde_change_global_key_provider_file('file_keyring5','$PGDATA/keyring_new.file');"

$INSTALL_DIR/bin/psql -d sbtest5 -c"CREATE TABLE t2(a INT, b varchar) USING tde_heap;"
$INSTALL_DIR/bin/psql -d sbtest5 -c"INSERT INTO t2 VALUES(200,'Rohit');"

echo "Fetch Principal Key Info"
$INSTALL_DIR/bin/psql -d sbtest5 -c"SELECT pg_tde_key_info();"
echo "..Verify Principal Key"
$INSTALL_DIR/bin/psql -d sbtest5 -c"SELECT pg_tde_verify_key();"

echo "..List of Global Key Providers"
$INSTALL_DIR/bin/psql -d sbtest5 -c"SELECT pg_tde_list_all_global_key_providers();"

echo "..Query tables t1, t2"
$INSTALL_DIR/bin/psql -d sbtest5 -c"SELECT * FROM t1;"
$INSTALL_DIR/bin/psql -d sbtest5 -c"SELECT * FROM t2;"

restart_pg $PGDATA $PORT

echo "..Query tables t1, t2"
$INSTALL_DIR/bin/psql -d sbtest5 -c"SELECT * FROM t1;"
$INSTALL_DIR/bin/psql -d sbtest5 -c"SELECT * FROM t2;"


echo "################################################################"
echo "# Scenario 6: Local Key Provider Change and Data Integrity     #"
echo "################################################################"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_kmip('kmip_keyring6','$kmip_server_address',$kmip_server_port,'$kmip_client_ca','$kmip_client_key','$kmip_server_ca');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('kmip_key6','kmip_keyring6');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_key_using_global_key_provider('kmip_key6','kmip_keyring6');"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE t1(a INT, b varchar) USING tde_heap;"
$INSTALL_DIR/bin/psql -d postgres -c"INSERT INTO t1 VALUES(100,'Mohit');"
$INSTALL_DIR/bin/psql -d postgres -c"INSERT INTO t1 VALUES(200,'Rohit');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1;"

$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_database_key_provider_vault_v2('vault_keyring6','$vault_url','$secret_mount_point', '$token_filepath', NULL, 'pg_tde_ns1/');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_database_key_provider('vault_key6','vault_keyring6');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_key_using_database_key_provider('vault_key6','vault_keyring6');"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE t2(a INT, b varchar) USING tde_heap;"
$INSTALL_DIR/bin/psql -d postgres -c"INSERT INTO t2 VALUES(100,'Mohit');"
$INSTALL_DIR/bin/psql -d postgres -c"INSERT INTO t2 VALUES(200,'Rohit');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t2;"

restart_pg $PGDATA $PORT
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1;"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t2;"
$INSTALL_DIR/bin/psql -d postgres -c"DROP TABLE t1;"
$INSTALL_DIR/bin/psql -d postgres -c"DROP TABLE t2;"

echo "#################################################################"
echo "# Scenario 7: Default Key Rotation with Global Key Provider     #"
echo "#################################################################"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_vault_v2('keyring_vault7','$vault_url','$secret_mount_point', '$token_filepath', NULL, 'pg_tde_ns1/');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('my_global_default_key1','keyring_vault7');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_default_key_using_global_key_provider('my_global_default_key1','keyring_vault7');"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;"
$INSTALL_DIR/bin/psql -d postgres -c"INSERT INTO t1 VALUES(101, 'James Bond');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1;"

echo "Rotate the Global Default Principal Key"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('my_global_default_key2','keyring_vault7');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_default_key_using_global_key_provider('my_global_default_key2','keyring_vault7');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1;"

echo "Add another Global Key Provider using KMIP"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_kmip('keyring_kmip7','$kmip_server_address',$kmip_server_port,'$kmip_client_ca','$kmip_client_key','$kmip_server_ca');"
echo "Rotate the Global Default Principal Key"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('my_global_default_key3','keyring_kmip7');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_default_key_using_global_key_provider('my_global_default_key3','keyring_kmip7');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1;"

echo "Add another Global Key Provider using file"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_file('keyring_file7','$PGDATA/keyring.file');"
echo "Rotate the Global Default Principal Key"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('my_global_default_key4','keyring_file7');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_default_key_using_global_key_provider('my_global_default_key4','keyring_file7');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1;"

restart_pg $PGDATA $PORT
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1;"
$INSTALL_DIR/bin/psql -d postgres -c"DROP TABLE t1;"

echo "#########################################################"
echo "# Scenario 8: Data Migration Between Key Providers      #"
echo "#########################################################"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE db8;"
$INSTALL_DIR/bin/psql -d db8 -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d db8 -c"SELECT pg_tde_add_database_key_provider_vault_v2('keyring_vault','$vault_url','$secret_mount_point', '$token_filepath', NULL, 'pg_tde_ns1/');"
$INSTALL_DIR/bin/psql -d db8 -c"SELECT pg_tde_create_key_using_database_key_provider('vault_key','keyring_vault');"
$INSTALL_DIR/bin/psql -d db8 -c"SELECT pg_tde_set_key_using_database_key_provider('vault_key','keyring_vault');"
$INSTALL_DIR/bin/psql -d db8 -c"CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;"
$INSTALL_DIR/bin/psql -d db8 -c"CREATE TABLE t2(a INT PRIMARY KEY, b VARCHAR) USING heap;"
$INSTALL_DIR/bin/psql -d db8 -c"INSERT INTO t1 VALUES(101, 'James Bond');"
$INSTALL_DIR/bin/psql -d db8 -c"INSERT INTO t2 VALUES(101, 'James Bond');"

$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE db8_new;"
$INSTALL_DIR/bin/psql -d db8_new -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d db8_new -c"SELECT pg_tde_add_database_key_provider_file('keyring_file','$PGDATA/keyring.file');"
$INSTALL_DIR/bin/psql -d db8_new -c"SELECT pg_tde_create_key_using_database_key_provider('file_key','keyring_file');"
$INSTALL_DIR/bin/psql -d db8_new -c"SELECT pg_tde_set_key_using_database_key_provider('file_key','keyring_file');"

echo "Taking pg_dump of table db8.t1"
rm -rf /tmp/t1.sql
$INSTALL_DIR/bin/pg_dump -d db8 -t t1 -t t2 -f /tmp/t1.sql

echo "Restore the dump on db8_new"
$INSTALL_DIR/bin/psql -d db8_new -f /tmp/t1.sql
restart_pg $PGDATA $PORT
$INSTALL_DIR/bin/psql -d db8_new -c"SELECT * FROM t1;"
$INSTALL_DIR/bin/psql -d db8_new -c"SELECT * FROM t2;"
echo "Rotate the Principal Key in db8_new"
$INSTALL_DIR/bin/psql -d db8_new -c"SELECT pg_tde_create_key_using_database_key_provider('file_key2','keyring_file');"
$INSTALL_DIR/bin/psql -d db8_new -c"SELECT pg_tde_set_key_using_database_key_provider('file_key2','keyring_file');"
echo "Change Key provider to kmip"
$INSTALL_DIR/bin/psql -d db8_new -c"SELECT pg_tde_add_database_key_provider_kmip('keyring_kmip','$kmip_server_address',$kmip_server_port,'$kmip_client_ca','$kmip_client_key','$kmip_server_ca');"
$INSTALL_DIR/bin/psql -d db8_new -c"SELECT pg_tde_create_key_using_database_key_provider('file_key2','keyring_kmip');"
$INSTALL_DIR/bin/psql -d db8_new -c"SELECT pg_tde_set_key_using_database_key_provider('file_key2','keyring_kmip');"
restart_pg $PGDATA $PORT
$INSTALL_DIR/bin/psql -d db8_new -c"SELECT * FROM t1;"
$INSTALL_DIR/bin/psql -d db8_new -c"SELECT * FROM t2;"

echo "################################################################################"
echo "# Scenario 9: Using Principal Keys provided by Local and Global Key Providers  #"
echo "################################################################################"

echo "..Add a global key provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_vault_v2('vault_keyring9','$vault_url','$secret_mount_point', '$token_filepath', NULL, 'pg_tde_ns1/');"
echo "..Set a default key for encryption"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('vault_key9','vault_keyring9');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_default_key_using_global_key_provider('vault_key9','vault_keyring9');"

echo "..Create Database test9"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE test9;"
$INSTALL_DIR/bin/psql -d test9 -c"CREATE EXTENSION pg_tde;"
# using default principal key
$INSTALL_DIR/bin/psql -d test9 -c"CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;"
$INSTALL_DIR/bin/psql -d test9 -c"INSERT INTO t1 VALUES(101, 'Ruskin Bond from t1');"
$INSTALL_DIR/bin/psql -d test9 -c"SELECT * FROM t1"

# lets rotate default key and create another table
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('vault_key91','vault_keyring9');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_default_key_using_global_key_provider('vault_key91','vault_keyring9');"
$INSTALL_DIR/bin/psql -d test9 -c"CREATE TABLE t2(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;"
$INSTALL_DIR/bin/psql -d test9 -c"INSERT INTO t2 VALUES(101, 'Ruskin Bond from t2');"
$INSTALL_DIR/bin/psql -d test9 -c"SELECT * FROM t2"
$INSTALL_DIR/bin/psql -d test9 -c"SELECT * FROM t1"

# adding local key provider
$INSTALL_DIR/bin/psql -d test9 -c"SELECT pg_tde_add_database_key_provider_file('keyring_file9','$PGDATA/keyring.file');"

# using principal key by local key provider and check if older tables are also re-encrypted
$INSTALL_DIR/bin/psql -d test9 -c"SELECT pg_tde_create_key_using_database_key_provider('file_key9','keyring_file9');"
$INSTALL_DIR/bin/psql -d test9 -c"SELECT pg_tde_set_key_using_database_key_provider('file_key9','keyring_file9');"
$INSTALL_DIR/bin/psql -d test9 -c"CREATE TABLE t3(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;"
$INSTALL_DIR/bin/psql -d test9 -c"INSERT INTO t3 VALUES(101, 'James Bond from t3');"
$INSTALL_DIR/bin/psql -d test9 -c"SELECT * FROM t3"
$INSTALL_DIR/bin/psql -d test9 -c"SELECT * FROM t1"
$INSTALL_DIR/bin/psql -d test9 -c"SELECT * FROM t2"

# rotate and use default principal key and check if all the tables are re-encrypted using default principal key
$INSTALL_DIR/bin/psql -d test9 -c"SELECT pg_tde_create_key_using_global_key_provider('vault_key92','vault_keyring9');"
$INSTALL_DIR/bin/psql -d test9 -c"SELECT pg_tde_set_key_using_global_key_provider('vault_key92','vault_keyring9');"

# deleting local key provider as this is not active. Must be successful
$INSTALL_DIR/bin/psql -d test9 -c"SELECT pg_tde_delete_database_key_provider('keyring_file9');"
# deleting local key. must pass
$INSTALL_DIR/bin/psql -d test9 -c"SELECT pg_tde_delete_key()"
echo "Must fail as the key is used for encryption"
$INSTALL_DIR/bin/psql -d test9 -c"SELECT pg_tde_delete_default_key()"

$INSTALL_DIR/bin/psql -d test9 -c"SELECT * FROM t1;"
$INSTALL_DIR/bin/psql -d test9 -c"SELECT * FROM t2;"
$INSTALL_DIR/bin/psql -d test9 -c"SELECT * FROM t3;"

restart_pg $PGDATA $PORT

$INSTALL_DIR/bin/psql -d test9 -c"DROP TABLE t1;"
$INSTALL_DIR/bin/psql -d test9 -c"DROP TABLE t2;"
$INSTALL_DIR/bin/psql -d test9 -c"DROP TABLE t3;"

# must be successful
$INSTALL_DIR/bin/psql -d test9 -c"SELECT pg_tde_delete_default_key()"

echo "##################################################################################################"
echo "# Scenario 10: Deleting a Global Key Provider while there are active local keys on the Database  #"
echo "##################################################################################################"
echo "..Add a global key provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_vault_v2('vault_keyring10','$vault_url','$secret_mount_point', '$token_filepath', NULL, 'pg_tde_ns1/');"
echo "..Create Database test10"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE test10"
$INSTALL_DIR/bin/psql -d test10 -c"CREATE EXTENSION pg_tde"

echo "..Set a local key for db test10 using global key provider"
$INSTALL_DIR/bin/psql -d test10 -c"SELECT pg_tde_create_key_using_global_key_provider('vault_key10','vault_keyring10');"
$INSTALL_DIR/bin/psql -d test10 -c"SELECT pg_tde_set_key_using_global_key_provider('vault_key10','vault_keyring10');"
$INSTALL_DIR/bin/psql -d test10 -c"CREATE TABLE t10(a int) USING tde_heap"
$INSTALL_DIR/bin/psql -d test10 -c"INSERT INTO t10 VALUES(10)"
$INSTALL_DIR/bin/psql -d test10 -c"SELECT * FROM t10"

echo "..Delete the Global Key provider. Must Fail"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_delete_global_key_provider('vault_keyring10')"

restart_pg $PGDATA $PORT
$INSTALL_DIR/bin/psql -d test10 -c"SELECT * FROM t10"

echo "############################################################################################"
echo "# Scenario 11: Deleting a Global Key Provider while there is active server key             #"
echo "############################################################################################"
echo "..Add a global key provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_vault_v2('vault_keyring11','$vault_url','$secret_mount_point', '$token_filepath', NULL, 'pg_tde_ns1/');"

echo "..Create Global server Key"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('server_key','vault_keyring11')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_server_key_using_global_key_provider('server_key','vault_keyring11')"

echo "Delete the Global Key Provider. Must fail as the server key is active and cannot be deleted"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_delete_global_key_provider('vault_keyring11')"

echo "Encrypt WAL"
$INSTALL_DIR/bin/psql -d postgres -c"ALTER SYSTEM SET pg_tde.wal_encrypt=ON"

restart_pg $PGDATA $PORT

echo "..Delete the Global Key provider. Must Fail as the key is active"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_delete_global_key_provider('vault_keyring11')"

$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_file('keyring_file11','$PGDATA/keyring.file')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('server_key','keyring_file11')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_server_key_using_global_key_provider('server_key','keyring_file11')"

echo "..Delete the old Global Key provider. Must be successful as the server key is active on new global provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_delete_global_key_provider('vault_keyring11')"


echo "################################################################################"
echo "# Scenario 12: Deleting Global Key Provider when the key is not active         #"
echo "################################################################################"

echo "..Add a global key provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_vault_v2('vault_keyring12','$vault_url','$secret_mount_point', '$token_filepath', NULL, 'pg_tde_ns1/');"
echo "..Set a default key for encryption"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('vault_key12','vault_keyring12');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_default_key_using_global_key_provider('vault_key12','vault_keyring12');"

$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_file('keyring_file12','$PGDATA/keyring.file')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('keyring_key12','keyring_file12');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_default_key_using_global_key_provider('keyring_key12','keyring_file12');"

# delete old key provider
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_delete_global_key_provider('vault_keyring12');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_delete_default_key()"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_delete_global_key_provider('keyring_file12');"
