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
# SOURCE share/install_rewriter.sql;  # Regrettably, this does not work, ref https://bugs.mysql.com/bug.php?id=87143
#   Do not use: SOURCE somesql.sql as SOURCE fails to work ([ERROR] 1064  You have an error in your SQL syntax)
#   Do not use: INSTALL PLUGIN rewriter SONAME 'rewriter.so' ref http://bugs.mysql.com/bug.php?id=83407
# This file has odd syntax requirements, ref https://bugs.mysql.com/bug.php?id=86303
#   Do not have remark lines at the top or middle of this file, only at the end
