INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';                   # YES
INSTALL PLUGIN rpl_semi_sync_slave SONAME 'semisync_slave.so';                     # YES
INSTALL PLUGIN scalability_metrics SONAME 'scalability_metrics.so';                # YES
INSTALL PLUGIN auth_pam SONAME 'auth_pam.so';                                      # YES
INSTALL PLUGIN auth_pam_compat SONAME 'auth_pam_compat.so';                        # YES
INSTALL PLUGIN query_response_time SONAME 'query_response_time.so';                # YES
INSTALL PLUGIN audit_log SONAME 'audit_log.so';                                    # YES
INSTALL PLUGIN tokudb SONAME 'ha_tokudb.so';                                       # YES
INSTALL PLUGIN tokudb_file_map SONAME 'ha_tokudb.so';    ## Need to research other ones whetter they have more then one function!!!!
INSTALL PLUGIN tokudb_fractal_tree_info SONAME 'ha_tokudb.so'; 
INSTALL PLUGIN tokudb_fractal_tree_block_map SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_trx SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_locks SONAME 'ha_tokudb.so';
INSTALL PLUGIN tokudb_lock_waits SONAME 'ha_tokudb.so';
INSTALL PLUGIN validate_password SONAME 'validate_password.so';                    # YES
INSTALL PLUGIN version_token SONAME 'version_token.so';                            # YES
INSTALL PLUGIN auth_socket SONAME 'auth_socket.so';                                # YES
INSTALL PLUGIN mysql_no_login SONAME 'mysql_no_login.so';                          # YES
INSTALL PLUGIN rewriter SONAME 'rewriter.so';                                      # YES
CREATE FUNCTION service_get_read_locks RETURNS INT SONAME 'locking_service.so';    # YES
CREATE FUNCTION service_get_write_locks RETURNS INT SONAME 'locking_service.so';   # YES
CREATE FUNCTION service_release_locks RETURNS INT SONAME 'locking_service.so';     # YES
CREATE FUNCTION fnv1a_64 RETURNS INTEGER SONAME 'libfnv1a_udf.so';                 # YES
CREATE FUNCTION fnv_64 RETURNS INTEGER SONAME 'libfnv_udf.so';                     # YES
CREATE FUNCTION murmur_hash RETURNS INTEGER SONAME 'libmurmur_udf.so';             # YES
#INSTALL PLUGIN ? SONAME 'auth.so';                                                 # WIP
#INSTALL PLUGIN adt_null SONAME 'adt_null.so';                                      # NO
#INSTALL PLUGIN dialog SONAME 'dialog.so';                                          # NO
#INSTALL PLUGIN qa_auth_interface SONAME 'qa_auth_interface.so';                    # NO
#INSTALL PLUGIN qa_auth_client SONAME 'qa_auth_client.so';                          # NO
#INSTALL PLUGIN qa_auth_server SONAME 'qa_auth_server.so';                          # NO
#INSTALL PLUGIN mypluglib SONAME 'mypluglib.so';                                    # NO
#INSTALL PLUGIN test_security_context SONAME 'test_security_context.so';            # NO
#INSTALL PLUGIN ? SONAME 'libtest_sql_shutdown.so';                                 # NO
#INSTALL PLUGIN ? SONAME 'libtest_services.so';                                     # NO
#INSTALL PLUGIN ? SONAME 'libtest_sql_all_col_types.so';                            # NO
#INSTALL PLUGIN ? SONAME 'libtest_session_detach.so';                               # NO
#INSTALL PLUGIN ? SONAME 'libtest_sql_processlist.so';                              # NO
#INSTALL PLUGIN ? SONAME 'libtest_x_sessions_deinit.so';                            # NO
#INSTALL PLUGIN ? SONAME 'libtest_services_threaded.so';                            # NO
#INSTALL PLUGIN ? SONAME 'libtest_session_in_thd.so';                               # NO
#INSTALL PLUGIN ? SONAME 'libtest_sql_commit.so';                                   # NO
#INSTALL PLUGIN ? SONAME 'libtest_sql_complex.so';                                  # NO
#INSTALL PLUGIN ? SONAME 'libtest_x_sessions_init.so';                              # NO
#INSTALL PLUGIN ? SONAME 'libtest_sql_lock.so';                                     # NO
#INSTALL PLUGIN ? SONAME 'libtest_sql_sqlmode.so';                                  # NO
#INSTALL PLUGIN ? SONAME 'libtest_sql_stored_procedures_functions.so';              # NO
#INSTALL PLUGIN ? SONAME 'libtest_sql_2_sessions.so';                               # NO
#INSTALL PLUGIN ? SONAME 'libtest_sql_errors.so';                                   # NO
#INSTALL PLUGIN ? SONAME 'libtest_sql_cmds_1.so';                                   # NO
#INSTALL PLUGIN ? SONAME 'libtest_framework.so';                                    # NO
#INSTALL PLUGIN ? SONAME 'libtest_sql_replication.so';                              # NO
#INSTALL PLUGIN ? SONAME 'libtest_session_info.so';                                 # NO
#INSTALL PLUGIN ? SONAME 'libtest_sql_views_triggers.so';                           # NO
#INSTALL PLUGIN ? SONAME 'libfnv_udf.so';                                           # NO
#INSTALL PLUGIN ? SONAME 'auth_test_plugin.so';                                     # NO
#INSTALL PLUGIN libdaemon_example SONAME 'libdaemon_example.so';                    # NO
#INSTALL PLUGIN ha_example SONAME 'ha_example.so';                                  # NO
#INSTALL PLUGIN ? SONAME 'replication_observers_example_plugin.so';                 # NO
#INSTALL PLUGIN rewrite_example SONAME 'rewrite_example.so';                        # NO (interesting for future QA: rewrite queries as subqueries etc.)
