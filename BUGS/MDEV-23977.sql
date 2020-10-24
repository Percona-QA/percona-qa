USE test;
SET SQL_MODE='';
SET GLOBAL aria_encrypt_tables=ON;
CREATE TABLE t (C1 CHAR (1) PRIMARY KEY, FOREIGN KEY(C1) REFERENCES t (C1)) ENGINE=Aria;
CREATE TRIGGER tr1_bi BEFORE INSERT ON t FOR EACH ROW SET @a:=1;
INSERT INTO t VALUES (str_to_date ('abcdefghijklmnopqrstuvwxyz', 'abcdefghijklmnopqrstuvwxyz'));
RENAME TABLE t TO t3,t TO t,t2 TO t;
