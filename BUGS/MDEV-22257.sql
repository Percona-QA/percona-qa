# mysqld options required for replay:  --sql_mode=
USE test;
CREATE TEMPORARY TABLE t (c INT);
SET @@SESSION.tx_read_only=1;
INSERT INTO t VALUES(0);
UPDATE t SET c=NULL;

# mysqld options required for replay: --sql_mode=
USE test;
CREATE TEMPORARY TABLE t (c INT) ENGINE=InnoDB;
INSERT INTO t VALUES (1);
START TRANSACTION READ ONLY;
UPDATE t SET c=0;

# mysqld options required for replay: --sql_mode=
USE test;
CREATE TEMPORARY TABLE t (c INT KEY) ENGINE=InnoDB;
INSERT INTO t VALUES (1);
START TRANSACTION READ ONLY;
UPDATE t SET c=0;
