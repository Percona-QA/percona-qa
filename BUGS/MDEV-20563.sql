CREATE  TABLE t1 (a INT, s BIGINT UNSIGNED AS ROW START, e BIGINT UNSIGNED AS ROW END, PERIOD FOR SYSTEM_TIME(s,e)) WITH SYSTEM VERSIONING ENGINE=InnoDB;
INSERT INTO t1 (a) VALUES (1),(2),(3),(4),(5),(6),(7),(8);
START TRANSACTION;
INSERT INTO t1 (a) VALUES (1),(2),(3),(4),(5),(6),(7),(8);
DELETE FROM t1;

CREATE TABLE t2 (a INT, KEY(a)) ENGINE=InnoDB;
INSERT INTO t2 (a) VALUES (1),(2),(3),(4),(5),(6),(7),(8);
CREATE  TABLE t1 (a INT, s BIGINT UNSIGNED AS ROW START, e BIGINT UNSIGNED AS ROW END, PERIOD FOR SYSTEM_TIME(s,e), FOREIGN KEY (a) REFERENCES t2(a)) WITH SYSTEM VERSIONING ENGINE=InnoDB;
INSERT INTO t1 (a) VALUES (1),(2),(3),(4),(5),(6),(7),(8);
START TRANSACTION;
INSERT INTO t1 (a) VALUES (1),(2),(3),(4),(5),(6),(7),(8);
DELETE FROM t1;

USE test;
CREATE TABLE t(i INT KEY,f INT) ENGINE=InnoDB;
INSERT INTO t VALUES (1,1);
ALTER TABLE t ADD COLUMN c1 BIGINT UNSIGNED AS ROW START INVISIBLE, ADD COLUMN c2 BIGINT UNSIGNED AS ROW END INVISIBLE, ADD PERIOD FOR SYSTEM_TIME(c1,c2), ADD SYSTEM VERSIONING;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
INSERT INTO t VALUES (7,0),(6,0),(5,0),(4,0),(3,0),(2,0),(100,0);
DELETE FROM t;
INSERT INTO t VALUES (0,0);
DELETE FROM t;

# Longer, partially uncleaned testcase, which may produce better reproducibility, though in the end the testcase just above this one also resulted in crash on shutdown, ref bug report
USE test;
CREATE TABLE t(i INT NOT NULL PRIMARY KEY, f INT) ENGINE = InnoDB;
CREATE TABLE servers (dummy int) ENGINE=innodb;
CREATE TABLE t6 (`bit_key` bit(14), `bit` bit, key (`bit_key` )) ENGINE=RocksDB;
CREATE TABLE `visits_events` ( `event_id` mediumint(8) unsigned NOT NULL DEFAULT '0', `visit_id` int(11) unsigned NOT NULL DEFAULT '0', `timestamp` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP, `src` varchar(64) NOT NULL DEFAULT '', `data` varchar(255) NOT NULL DEFAULT '', `visits_events_id` int(11) unsigned NOT NULL AUTO_INCREMENT, PRIMARY KEY (`visits_events_id`), KEY `event_id` (`event_id`), KEY `visit_id` (`visit_id`), KEY `data` (`data`) ) ENGINE=MyISAM AUTO_INCREMENT=33900731 DEFAULT CHARSET=latin1;
CREATE TABLE mt2 (c1 INT NOT NULL PRIMARY KEY, c2 INTEGER, KEY(c2));
CREATE TABLE `Ｔ９` (`Ｃ１` char(12), INDEX(`Ｃ１`)) DEFAULT CHARSET = utf8 engine = MEMORY;
CREATE TABLE ti (a TINYINT UNSIGNED NOT NULL, b TINYINT UNSIGNED NOT NULL, c BINARY(50) NOT NULL, d VARCHAR(93) NOT NULL, e VARBINARY(56), f VARBINARY(36) NOT NULL, g LONGBLOB NOT NULL, h MEDIUMBLOB NOT NULL, id BIGINT NOT NULL, KEY(b), KEY(e), PRIMARY KEY(id)) ENGINE=RocksDB;
CREATE TABLE t2 (c1 CHAR(2) CHARACTER SET 'Binary' COLLATE 'Binary',c2 INTEGER ZEROFILL,c3 VARCHAR(2037) CHARACTER SET 'latin1' COLLATE 'latin1_bin') ENGINE=InnoDB;
CREATE TABLE `�ԣ�b` (`�ã�` char(1) PRIMARY KEY) DEFAULT CHARSET = ujis engine = TokuDB;
INSERT IGNORE INTO t VALUES (NULL,0),(NULL,0),(0,21),(4,0),(1,8),(5,66);
alter table t add column trx_start bigint(20) unsigned as row start invisible, add column trx_end bigint(20) unsigned as row end invisible, add period for system_time(trx_start, trx_end), add system versioning;
CREATE TABLE t1 ( id int(11) NOT NULL AUTO_INCREMENT, parent_id smallint(3) NOT NULL DEFAULT '0', col2 varchar(25) NOT NULL DEFAULT '', PRIMARY KEY (id) ) ENGINE=INNODB;
create table t11(a int) engine= Aria;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
insert into t values (5390,0);
insert into t values (8677,0);
insert into t values (9563,0);
insert into t values (3207,0);
insert into t values (5123,0);
insert into t values (700,0);
set global table_open_cache=10;
insert into t values (757,0);
delete from t;
select constraint_name from information_schema.table_constraints where table_schema='test'; ;
select constraint_name from information_schema.table_constraints where table_schema='test'; ;
SELECT 1;

USE test;
SET SQL_MODE='';
CREATE TABLE t (i INT PRIMARY KEY, f INT) ENGINE = InnoDB;
INSERT IGNORE INTO t VALUES (NULL,0),(NULL,0),(0,21),(4,0),(1,8),(5,66);
ALTER TABLE t ADD COLUMN trx_start BIGINT(20) UNSIGNED AS ROW START INVISIBLE, ADD COLUMN trx_end BIGINT(20) UNSIGNED AS ROW END INVISIBLE, ADD PERIOD FOR SYSTEM_TIME(trx_start, trx_end), ADD SYSTEM VERSIONING;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
INSERT INTO t VALUES (5390,0),(8677,0),(9563,0),(3207,0),(5123,0),(700,0),(757,0);
DELETE FROM t;
# Last statement immediately crashes debug. Optimized builds requires mysqladmin shutdown and then crashes.
