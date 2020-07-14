SET @@SESSION.wsrep_causal_reads=ON;
SET SESSION wsrep_on=1;
START TRANSACTION READ WRITE;

SET NAMES utf8, collation_connection='utf16le_bin';
SET GLOBAL wsrep_provider='/invalid/libgalera_smm.so';
SET GLOBAL wsrep_cluster_address=AUTO;
SET GLOBAL wsrep_slave_threads=2;
