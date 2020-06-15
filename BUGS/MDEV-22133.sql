RENAME TABLE mysql.procs_priv TO mysql.procs_gone;
CREATE USER a@localhost;

RENAME TABLE mysql.procs_priv TO mysql.procs_priv_backup;  # MDEV-22319 dup of MDEV-22133
DROP USER a;

RENAME TABLE mysql.procs_priv TO procs_priv_backup;
RENAME USER '0'@'0' to '0'@'0';

RENAME TABLE mysql.procs_priv TO mysql.procs_gone;
RENAME USER _B@'' TO _C@'';

USE test;
CREATE TABLE t (c1 SMALLINT(254),c2 BIGINT(254),c3 DECIMAL(65,30) ZEROFILL) ENGINE=MyISAM PARTITION BY HASH((c1)) PARTITIONS 852;
INSERT INTO t VALUES ('','','');
RENAME TABLE mysql.procs_priv TO procs_priv_backup;
CREATE USER 'test_user'@'localhost';

USE test;
CREATE TABLE t2 (c1 SMALLINT(254),c2 BIGINT(254),c3 DECIMAL(65,30) ZEROFILL) ENGINE=MyISAM PARTITION BY HASH((c1)) PARTITIONS 852;
INSERT INTO t2 VALUES  ('aaa','aaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
RENAME TABLE mysql.procs_priv TO procs_priv_backup;
create user 'test_user'@'localhost';
