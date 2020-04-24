USE test;
CREATE TABLE t(c int) ENGINE=Aria;
SET @@SESSION.default_master_connection='0';
CHANGE MASTER TO master_use_gtid=slave_pos;
SET @@GLOBAL.replicate_wild_ignore_table='';
