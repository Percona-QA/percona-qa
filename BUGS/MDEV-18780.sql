CREATE TABLE t1 (pk INT PRIMARY KEY) ENGINE=InnoDB ROW_FORMAT=REDUNDANT;
ALTER TABLE t1 DROP PRIMARY KEY;
ALTER TABLE t1 ADD d INT;
ALTER TABLE t1 CHANGE pk f INT;