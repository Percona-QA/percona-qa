SET GLOBAL innodb_trx_rseg_n_slots_debug=1;
CREATE TABLE t (b TEXT, FULLTEXT (b)) ENGINE=InnoDB;
INSERT INTO t VALUES ('a');
DELETE FROM t;
