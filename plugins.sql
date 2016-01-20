INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';                     # YES, DONE
INSTALL PLUGIN rpl_semi_sync_slave SONAME 'semisync_slave.so';                       # YES, DONE
INSTALL PLUGIN scalability_metrics SONAME 'scalability_metrics.so';                  # YES, DONE
INSTALL PLUGIN auth_pam SONAME 'auth_pam.so';                                        # YES, DONE
INSTALL PLUGIN auth_pam_compat SONAME 'auth_pam_compat.so';                          # YES, DONE
INSTALL PLUGIN QUERY_RESPONSE_TIME SONAME 'query_response_time.so';                  # YES, DONE
INSTALL PLUGIN QUERY_RESPONSE_TIME_AUDIT SONAME 'query_response_time.so';            # YES, DONE
INSTALL PLUGIN QUERY_RESPONSE_TIME_READ SONAME 'query_response_time.so';             # YES, DONE
INSTALL PLUGIN QUERY_RESPONSE_TIME_WRITE SONAME 'query_response_time.so';            # YES, DONE
INSTALL PLUGIN audit_log SONAME 'audit_log.so';                                      # YES, DONE
INSTALL PLUGIN tokudb SONAME 'ha_tokudb.so';                                         # YES, DONE
INSTALL PLUGIN tokudb_file_map SONAME 'ha_tokudb.so';                                # YES, DONE
INSTALL PLUGIN tokudb_fractal_tree_info SONAME 'ha_tokudb.so';                       # YES, DONE
INSTALL PLUGIN tokudb_fractal_tree_block_map SONAME 'ha_tokudb.so';                  # YES, DONE
INSTALL PLUGIN tokudb_trx SONAME 'ha_tokudb.so';                                     # YES, DONE
INSTALL PLUGIN tokudb_locks SONAME 'ha_tokudb.so';                                   # YES, DONE
INSTALL PLUGIN tokudb_lock_waits SONAME 'ha_tokudb.so';                              # YES, DONE
INSTALL PLUGIN tokudb_background_job_status SONAME 'ha_tokudb.so';                   # YES, DONE
INSTALL PLUGIN validate_password SONAME 'validate_password.so';                      # YES, DONE
INSTALL PLUGIN version_tokens SONAME 'version_token.so';                             # YES, DONE
CREATE FUNCTION version_tokens_set RETURNS STRING SONAME 'version_token.so';         # YES, DONE
CREATE FUNCTION version_tokens_show RETURNS STRING SONAME 'version_token.so';        # YES, DONE
CREATE FUNCTION version_tokens_edit RETURNS STRING SONAME 'version_token.so';        # YES, DONE
CREATE FUNCTION version_tokens_delete RETURNS STRING SONAME 'version_token.so';      # YES, DONE
CREATE FUNCTION version_tokens_lock_shared RETURNS INT SONAME 'version_token.so';    # YES, DONE
CREATE FUNCTION version_tokens_lock_exclusive RETURNS INT SONAME 'version_token.so'; # YES, DONE
CREATE FUNCTION version_tokens_unlock RETURNS INT SONAME 'version_token.so';         # YES, DONE
INSTALL PLUGIN auth_socket SONAME 'auth_socket.so';                                  # YES, DONE
INSTALL PLUGIN mysql_no_login SONAME 'mysql_no_login.so';                            # YES, DONE
INSTALL PLUGIN rewriter SONAME 'rewriter.so';                                        # YES, DONE
CREATE FUNCTION service_get_read_locks RETURNS INT SONAME 'locking_service.so';      # YES, DONE
CREATE FUNCTION service_get_write_locks RETURNS INT SONAME 'locking_service.so';     # YES, DONE
CREATE FUNCTION service_release_locks RETURNS INT SONAME 'locking_service.so';       # YES, DONE
CREATE FUNCTION fnv1a_64 RETURNS INTEGER SONAME 'libfnv1a_udf.so';                   # YES, DONE
CREATE FUNCTION fnv_64 RETURNS INTEGER SONAME 'libfnv_udf.so';                       # YES, DONE
CREATE FUNCTION murmur_hash RETURNS INTEGER SONAME 'libmurmur_udf.so';               # YES, DONE
#INSTALL PLUGIN ? SONAME 'auth.so';                                                   # WIP
