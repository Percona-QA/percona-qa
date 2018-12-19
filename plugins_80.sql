INSTALL PLUGIN tokudb_file_map SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_fractal_tree_info SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_fractal_tree_block_map SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_trx SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_locks SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_lock_waits SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_background_job_status SONAME 'ha_tokudb.so';
INSTALL PLUGIN rocksdb_cfstats SONAME 'ha_rocksdb.so';
INSTALL PLUGIN rocksdb_dbstats SONAME 'ha_rocksdb.so';
INSTALL PLUGIN rocksdb_perf_context SONAME 'ha_rocksdb.so';
INSTALL PLUGIN rocksdb_perf_context_global SONAME 'ha_rocksdb.so';
INSTALL PLUGIN rocksdb_cf_options SONAME 'ha_rocksdb.so';
INSTALL PLUGIN rocksdb_compaction_stats SONAME 'ha_rocksdb.so';
INSTALL PLUGIN rocksdb_global_info SONAME 'ha_rocksdb.so';
INSTALL PLUGIN rocksdb_ddl SONAME 'ha_rocksdb.so';
INSTALL PLUGIN rocksdb_index_file_map SONAME 'ha_rocksdb.so';
INSTALL PLUGIN rocksdb_locks SONAME 'ha_rocksdb.so';
INSTALL PLUGIN rocksdb_trx SONAME 'ha_rocksdb.so';
INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';
INSTALL PLUGIN rpl_semi_sync_slave SONAME 'semisync_slave.so';
INSTALL PLUGIN validate_password SONAME 'validate_password.so';
INSTALL PLUGIN version_tokens SONAME 'version_token.so';
CREATE FUNCTION version_tokens_set RETURNS STRING SONAME 'version_token.so';
CREATE FUNCTION version_tokens_show RETURNS STRING SONAME 'version_token.so';
CREATE FUNCTION version_tokens_edit RETURNS STRING SONAME 'version_token.so';
CREATE FUNCTION version_tokens_delete RETURNS STRING SONAME 'version_token.so';
CREATE FUNCTION version_tokens_lock_shared RETURNS INT SONAME 'version_token.so';
CREATE FUNCTION version_tokens_lock_exclusive RETURNS INT SONAME 'version_token.so';
CREATE FUNCTION version_tokens_unlock RETURNS INT SONAME 'version_token.so';
INSTALL PLUGIN auth_socket SONAME 'auth_socket.so';
INSTALL PLUGIN mysql_no_login SONAME 'mysql_no_login.so';
CREATE FUNCTION service_get_read_locks RETURNS INT SONAME 'locking_service.so';
CREATE FUNCTION service_get_write_locks RETURNS INT SONAME 'locking_service.so';
CREATE FUNCTION service_release_locks RETURNS INT SONAME 'locking_service.so';
CREATE FUNCTION fnv1a_64 RETURNS INTEGER SONAME 'libfnv1a_udf.so';
CREATE FUNCTION fnv_64 RETURNS INTEGER SONAME 'libfnv_udf.so';
CREATE FUNCTION murmur_hash RETURNS INTEGER SONAME 'libmurmur_udf.so';
INSTALL PLUGIN audit_log SONAME 'audit_log.so';
INSTALL PLUGIN auth_pam SONAME 'auth_pam.so'; # https://jira.percona.com/browse/PS-4898
INSTALL PLUGIN auth_pam_compat SONAME 'auth_pam_compat.so'; # Idem
# INSTALL PLUGIN mysqlx SONAME 'mysqlx.so';  # Automatically loaded in 8.0 (it is now built in alike to InnoDB, no more actual mysqlx.so file)
# INSTALL PLUGIN ha_mock SONAME 'ha_mock.so';  # Ref https://dev.mysql.com/doc/dev/mysql-server/8.0.13/classmock_1_1ha__mock.html - may be interesting for later exploratory testing (check INSTALL PLUGIN command at that time)
# keyring_vault.so; this plugin requires early load, so best to pass in MYEXTRA as extra param
# dialog.so; as per LB this is a client-side plugin (related to PAM), and there is nothing that can be done with it server-side, it can be ignored here. Also ref https://www.percona.com/doc/percona-server/5.7/management/pam_plugin.html 
# As per PS-4662, the query_response_time.so plugin has been removed
# SOURCE share/install_rewriter.sql;  # Regrettably, this does not work, ref https://bugs.mysql.com/bug.php?id=87143
#   Do not use: SOURCE somesql.sql as SOURCE fails to work ([ERROR] 1064  You have an error in your SQL syntax)
#   Do not use: INSTALL PLUGIN rewriter SONAME 'rewriter.so' ref http://bugs.mysql.com/bug.php?id=83407
# INSTALL PLUGIN tokudb SONAME 'ha_tokudb.so';  # Disabled, because pquery-run.sh preloads this (it does so to enable TokuDB --options to be used with mysqld) (if set in MYEXTRA) ([re]moved from above tokudb_file_map to here because;)
# This file has odd syntax requirements, ref https://bugs.mysql.com/bug.php?id=86303
#   Do not have remark lines at the top or middle of this file, only at the end
