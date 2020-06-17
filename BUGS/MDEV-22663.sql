USE test;
SET SQL_MODE='';
CREATE TABLE t (id INT);
INSERT INTO t VALUES (1);
INSERT INTO t VALUES (2);
INSERT INTO t VALUES (3);
INSERT INTO t VALUES (4);
ALTER TABLE mysql.help_keyword engine=InnoDB;
HELP going_to_crash;

# mysqld options required for replay:  --thread_handling=pool-of-threads
USE test;
SET SQL_MODE='';
CREATE TABLE t(c INT UNSIGNED AUTO_INCREMENT NULL UNIQUE KEY) AUTO_INCREMENT=10;
insert INTO t VALUES ('abcdefghijklmnopqrstuvwxyz');
ALTER TABLE t ALGORITHM=INPLACE, ENGINE=InnoDB;
DELETE FROM t ;
INSERT INTO t VALUES(3872);
ALTER TABLE mysql.help_topic ENGINE=InnoDB;
HELP no_such_topic;
