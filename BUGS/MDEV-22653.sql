USE test;
SET GLOBAL innodb_simulate_comp_failures=99;  # (!)
CREATE TABLE t(c INT);
INSERT INTO t VALUES (1),(1),(1);
ALTER TABLE t KEY_BLOCK_SIZE=2;
