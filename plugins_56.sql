INSTALL PLUGIN tokudb_file_map SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_fractal_tree_info SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_fractal_tree_block_map SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_trx SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_locks SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_lock_waits SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_background_job_status SONAME 'ha_tokudb.so';
INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';
INSTALL PLUGIN rpl_semi_sync_slave SONAME 'semisync_slave.so';
INSTALL PLUGIN auth_pam SONAME 'auth_pam.so';
INSTALL PLUGIN auth_pam_compat SONAME 'auth_pam_compat.so';
INSTALL PLUGIN QUERY_RESPONSE_TIME SONAME 'query_response_time.so';
INSTALL PLUGIN QUERY_RESPONSE_TIME_AUDIT SONAME 'query_response_time.so';
INSTALL PLUGIN QUERY_RESPONSE_TIME_READ SONAME 'query_response_time.so';
INSTALL PLUGIN QUERY_RESPONSE_TIME_WRITE SONAME 'query_response_time.so';
INSTALL PLUGIN validate_password SONAME 'validate_password.so';
INSTALL PLUGIN auth_socket SONAME 'auth_socket.so';
INSTALL PLUGIN mysql_no_login SONAME 'mysql_no_login.so';
CREATE FUNCTION fnv1a_64 RETURNS INTEGER SONAME 'libfnv1a_udf.so';
CREATE FUNCTION fnv_64 RETURNS INTEGER SONAME 'libfnv_udf.so';
CREATE FUNCTION murmur_hash RETURNS INTEGER SONAME 'libmurmur_udf.so';
INSTALL PLUGIN audit_log SONAME 'audit_log.so';
# INSTALL PLUGIN tokudb SONAME 'ha_tokudb.so';  # Disabled, because pquery-run.sh preloads this (it does so to enable TokuDB --options to be used with mysqld) (if set in MYEXTRA) ([re]moved from above tokudb_file_map to here because;)
# This file has odd syntax requirements, ref https://bugs.mysql.com/bug.php?id=86303
# Do not have remark lines at the top or middle of this file, only at the end
