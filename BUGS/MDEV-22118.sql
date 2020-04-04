# mysqld options required for replay:  --sql_mode= 
CREATE TABLE t (c INT AUTO_INCREMENT KEY);
SET @@SESSION.insert_id=-0;  # Or -1, -2 etc.
INSERT INTO t VALUES(0);
