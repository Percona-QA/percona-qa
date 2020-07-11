SET COLLATION_CONNECTION='utf16le_bin';
SET GLOBAL wsrep_provider='/invalid/libgalera_smm.so';
SET GLOBAL wsrep_cluster_address='OFF';
SET GLOBAL wsrep_slave_threads=10;
SELECT 1;

SET NAMES utf8, collation_connection='utf16le_bin';
SET @@global.wsrep_provider='/invalid/libgalera_smm.so';
SET @@global.wsrep_cluster_address=AUTO;
SET GLOBAL wsrep_slave_threads = 2;
SELECT SLEEP(2);
CREATE TABLE t (c INT);
