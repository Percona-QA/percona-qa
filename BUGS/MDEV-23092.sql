SET COLLATION_CONNECTION='utf16le_bin';
SET GLOBAL wsrep_provider='/invalid/libgalera_smm.so';
SET GLOBAL wsrep_cluster_address='OFF';
SET GLOBAL wsrep_slave_threads=10;
SELECT 1;
