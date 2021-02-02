DROP DATABASE test;
CREATE DATABASE test;
USE test;
SET SESSION aria_repair_threads=CAST(-1 AS UNSIGNED INT);
SET SESSION aria_sort_buffer_size=CAST(-1 AS UNSIGNED INT);
SET SESSION tmp_table_size=65535;
CREATE TABLE tproc LIKE tstmt;
CREATE TABLE t1 (a BIT(7));
INSERT INTO t1 VALUES('C'), ('c');
INSERT INTO t1 VALUES(1550);
ALTER TABLE t1 modify a VARCHAR(255);
XA BEGIN 'a';
INSERT INTO t1 (a) VALUES('üc'), ('uc'), ('ue'), ('ud'), ('Ü'), ('ueb'), ('uf');
INSERT INTO t1 VALUES('2001-01-01 00:00:01.000000');
INSERT INTO t1 VALUES('a');
INSERT INTO at (c,_boo) SELECT CONCAT ('_boo: ',c), (SELECT j FROM t WHERE c='stringdecimal') FROM t WHERE c='stringdecimal';
INSERT INTO t1 VALUES(_ucs2 0x010c), (_ucs2 0x010d), (_ucs2 0x010e), (_ucs2 0x010f);
INSERT INTO t1 VALUES(1), (3);
INSERT INTO t1 VALUES(0xACD4);
INSERT INTO t1 VALUES(0xABA8);
INSERT INTO t1 VALUES(1);
INSERT INTO t1 VALUES(0xF48F8080);
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES(0xA9A2);
INSERT t1 VALUES(30), (1230), ("1230"), ("12:30"), ("12:30:35"), ("1 12:30:31.32");
INSERT INTO t1 VALUES("19991101000000"), ("19990102030405"), ("19990630232922"), ("19990601000000");
INSERT INTO t1 VALUES('2004-01-01'), ('2004-02-29');
INSERT INTO t1 SELECT 2*a+3 FROM t1;
INSERT INTO t1 VALUES('2001-01-01 10:10:10.999993');
INSERT INTO t1 VALUES(0xADE5);
INSERT INTO t1 VALUES('');
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES('a');
INSERT INTO t1 VALUES('Z');
INSERT INTO t1 VALUES(12704);
INSERT INTO t1 VALUES('0.1');
INSERT INTO t1 VALUES('698aaaaaaaaaaaaaaaaaaaaaaaaaa');
INSERT INTO t1 VALUES(0xA9AA);
INSERT INTO t1 VALUES(unhex (hex (132)));
INSERT INTO t1 VALUES(1), (2), (1), (2), (1), (2), (3);
INSERT IGNORE INTO t1 VALUES(@inserted_value);
INSERT INTO t1 VALUES(15416);
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
COMMIT;
INSERT INTO t1 VALUES('C'), ('c');
INSERT INTO t1 VALUES(1550);
ALTER TABLE t1 modify a VARCHAR(255);
INSERT INTO t1 (a) VALUES('üc'), ('uc'), ('ue'), ('ud'), ('Ü'), ('ueb'), ('uf');
INSERT INTO t1 VALUES('2001-01-01 00:00:01.000000');
INSERT INTO t1 VALUES('a');
INSERT INTO at (c,_boo) SELECT CONCAT ('_boo: ',c), (SELECT j FROM t WHERE c='stringdecimal') FROM t WHERE c='stringdecimal';
INSERT INTO t1 VALUES(_ucs2 0x010c), (_ucs2 0x010d), (_ucs2 0x010e), (_ucs2 0x010f);
INSERT INTO t1 VALUES(1), (3);
INSERT INTO t1 VALUES(0xACD4);
INSERT INTO t1 VALUES(0xABA8);
INSERT INTO t1 VALUES(1);
INSERT INTO t1 VALUES(0xF48F8080);
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES(0xA9A2);
INSERT t1 VALUES(30), (1230), ("1230"), ("12:30"), ("12:30:35"), ("1 12:30:31.32");
INSERT INTO t1 VALUES("19991101000000"), ("19990102030405"), ("19990630232922"), ("19990601000000");
INSERT INTO t1 VALUES('2004-01-01'), ('2004-02-29');
INSERT INTO t1 SELECT 2*a+3 FROM t1;
INSERT INTO t1 VALUES('2001-01-01 10:10:10.999993');
INSERT INTO t1 VALUES(0xADE5);
INSERT INTO t1 VALUES('');
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES('a');
INSERT INTO t1 VALUES('Z');
INSERT INTO t1 VALUES(12704);
INSERT INTO t1 VALUES('0.1');
INSERT INTO t1 VALUES('698aaaaaaaaaaaaaaaaaaaaaaaaaa');
INSERT INTO t1 VALUES(0xA9AA);
INSERT INTO t1 VALUES(unhex (hex (132)));
INSERT INTO t1 VALUES(1), (2), (1), (2), (1), (2), (3);
INSERT IGNORE INTO t1 VALUES(@inserted_value);
INSERT INTO t1 VALUES(15416);
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
XA END 'a';
DROP DATABASE test;
CREATE DATABASE test;
USE test;

DROP DATABASE test;
CREATE DATABASE test;
USE test;
CREATE TABLE tproc LIKE tstmt;#ERROR: 1146 - Table 'test.tstmt' doesn't exist
set session aria_sort_buffer_size=cast(-1 as unsigned int);#NOERROR
create table t1(a bit(7));#NOERROR
insert INTO t1  values ('C'),('c');#NOERROR
insert into t1 values(1550);#NOERROR
alter TABLE t1 modify a varchar(255);#NOERROR
xa begin 'a','ab';#NOERROR
set session aria_repair_threads=cast(-1 as unsigned int);#NOERROR
insert into t1 (a) values ('üc'),('uc'),('ue'),('ud'),('Ü'),('ueb'),('uf');#ERROR: 1054 - Unknown column 'a' in 'field list'
INSERT INTO t1  VALUES ('2001-01-01 00:00:01.000000');#NOERROR
INSERT INTO t1  VALUES('a');#NOERROR
insert into at(c,_boo) select concat('_boo: ',c), (select j from t where c='stringdecimal') from t where c='stringdecimal';#ERROR: 1146 - Tabela 'test.at' ne postoji
insert INTO t1  values (_ucs2 0x010c),(_ucs2 0x010d),(_ucs2 0x010e),(_ucs2 0x010f);#NOERROR
insert INTO t1  values (1), (3);#NOERROR
INSERT INTO t1 VALUES(0xACD4);#NOERROR
INSERT INTO t1  VALUES(0xABA8);#NOERROR
INSERT INTO t1  VALUES(1);#NOERROR
insert into t1 values (0xF48F8080);#NOERROR
delete from mysql.user where user='mysqltest_4';#ERROR: 1175 - Vi koristite safe update mod servera, a probali ste da promenite podatke bez 'WHERE' komande koja koristi kolonu klju\010Da
INSERT INTO t1  SELECT * FROM t1 ;#NOERROR
INSERT INTO t1 VALUES(0xA9A2);#NOERROR
insert t1 values (30),(1230),("1230"),("12:30"),("12:30:35"),("1 12:30:31.32");#ERROR: 1054 - Nepoznata kolona '1230' u 'field list'
insert into t1 values ("19991101000000"),("19990102030405"),("19990630232922"),("19990601000000");#ERROR: 1054 - Nepoznata kolona '19991101000000' u 'field list'
INSERT INTO t1 VALUES('2004-01-01'),('2004-02-29');#NOERROR
INSERT INTO t1  SELECT 2*a+3 FROM t1 ;#NOERROR
INSERT INTO t1  VALUES ('2001-01-01 10:10:10.999993');#NOERROR
INSERT INTO t1  VALUES(0xADE5);#NOERROR
INSERT INTO t1 VALUES('');#NOERROR
INSERT INTO t1  SELECT * FROM t1 ;#NOERROR
INSERT INTO t1  VALUES('a');#NOERROR
INSERT INTO t1 VALUES ('Z');#NOERROR
SET @@session.tmp_table_size = 65535;#NOERROR
INSERT INTO t1 VALUES(12704);#NOERROR
INSERT INTO t1  VALUES ('0.1');#NOERROR
INSERT INTO t1 VALUES('698aaaaaaaaaaaaaaaaaaaaaaaaaa');#ERROR: 1265 - Data truncated for column 'c1' at row 1
INSERT INTO t1 VALUES(0xA9AA);#NOERROR
INSERT INTO t1 VALUES (unhex(hex(132)));#NOERROR
insert into t1 values(1),(2),(1),(2),(1),(2),(3);#NOERROR
INSERT IGNORE INTO t1 VALUES(@inserted_value);#NOERROR
INSERT INTO t1 VALUES(15416);#NOERROR
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
DROP DATABASE test;
CREATE DATABASE test;
USE test;
CREATE TABLE tproc LIKE tstmt;#ERROR: 1146 - Table 'test.tstmt' doesn't exist
set session aria_sort_buffer_size=cast(-1 as unsigned int);#NOERROR
create table t1(a bit(7));#NOERROR
insert INTO t1  values ('C'),('c');#NOERROR
insert into t1 values(1550);#NOERROR
alter TABLE t1 modify a varchar(255);#NOERROR
xa begin 'a','ab';#NOERROR
set session aria_repair_threads=cast(-1 as unsigned int);#NOERROR
insert into t1 (a) values ('üc'),('uc'),('ue'),('ud'),('Ü'),('ueb'),('uf');#ERROR: 1054 - Unknown column 'a' in 'field list'
INSERT INTO t1  VALUES ('2001-01-01 00:00:01.000000');#NOERROR
INSERT INTO t1  VALUES('a');#NOERROR
insert into at(c,_boo) select concat('_boo: ',c), (select j from t where c='stringdecimal') from t where c='stringdecimal';#ERROR: 1146 - Tabela 'test.at' ne postoji
insert INTO t1  values (_ucs2 0x010c),(_ucs2 0x010d),(_ucs2 0x010e),(_ucs2 0x010f);#NOERROR
insert INTO t1  values (1), (3);#NOERROR
INSERT INTO t1 VALUES(0xACD4);#NOERROR
INSERT INTO t1  VALUES(0xABA8);#NOERROR
INSERT INTO t1  VALUES(1);#NOERROR
insert into t1 values (0xF48F8080);#NOERROR
delete from mysql.user where user='mysqltest_4';#ERROR: 1175 - Vi koristite safe update mod servera, a probali ste da promenite podatke bez 'WHERE' komande koja koristi kolonu klju\010Da
INSERT INTO t1  SELECT * FROM t1 ;#NOERROR
INSERT INTO t1 VALUES(0xA9A2);#NOERROR
insert t1 values (30),(1230),("1230"),("12:30"),("12:30:35"),("1 12:30:31.32");#ERROR: 1054 - Nepoznata kolona '1230' u 'field list'
insert into t1 values ("19991101000000"),("19990102030405"),("19990630232922"),("19990601000000");#ERROR: 1054 - Nepoznata kolona '19991101000000' u 'field list'
INSERT INTO t1 VALUES('2004-01-01'),('2004-02-29');#NOERROR
INSERT INTO t1  SELECT 2*a+3 FROM t1 ;#NOERROR
INSERT INTO t1  VALUES ('2001-01-01 10:10:10.999993');#NOERROR
INSERT INTO t1  VALUES(0xADE5);#NOERROR
INSERT INTO t1 VALUES('');#NOERROR
INSERT INTO t1  SELECT * FROM t1 ;#NOERROR
INSERT INTO t1  VALUES('a');#NOERROR
INSERT INTO t1 VALUES ('Z');#NOERROR
SET @@session.tmp_table_size = 65535;#NOERROR
INSERT INTO t1 VALUES(12704);#NOERROR
INSERT INTO t1  VALUES ('0.1');#NOERROR
INSERT INTO t1 VALUES('698aaaaaaaaaaaaaaaaaaaaaaaaaa');#ERROR: 1265 - Data truncated for column 'c1' at row 1
INSERT INTO t1 VALUES(0xA9AA);#NOERROR
INSERT INTO t1 VALUES (unhex(hex(132)));#NOERROR
insert into t1 values(1),(2),(1),(2),(1),(2),(3);#NOERROR
INSERT IGNORE INTO t1 VALUES(@inserted_value);#NOERROR
INSERT INTO t1 VALUES(15416);#NOERROR
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;
update t1 set a = ((select max(a) from t1)); ;

CREATE TABLE t1 (a VARCHAR(255));
INSERT INTO t1 VALUES('C'),('c');
XA BEGIN 'a','ab';
INSERT INTO t1 VALUES('2001-01-01 00:00:01.000000'),('a'),(1),(3),(0xACD4),(0xABA8),(1),(0xF48F8080);
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES(0xA9A2),(30),(1230),("1230"),("12:30"),("12:30:35"),("1 12:30:31.32"),("19991101000000"),("19990102030405"),("19990630232922"),("19990601000000"),('2004-01-01'),('2004-02-29'),('2001-01-01 10:10:10.999993'),(0xADE5),('');
SET SESSION tmp_table_size=65535;
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES('a'),('Z'),(12704),('0.1'),('698aaaaaaaaaaaaaaaaaaaaaaaaaa'),(0xA9AA),(unhex (hex (132))),(1),(2),(1),(2),(1),(2),(3);
INSERT INTO t1 VALUES('Z');
INSERT INTO t1 VALUES(12704);
INSERT INTO t1 VALUES('0.1');
INSERT INTO t1 VALUES('698aaaaaaaaaaaaaaaaaaaaaaaaaa');
INSERT INTO t1 VALUES(0xA9AA);
INSERT INTO t1 VALUES(unhex (hex (132)));
INSERT INTO t1 VALUES(1),(2),(1),(2),(1),(2),(3);
INSERT IGNORE INTO t1 VALUES(@inserted_value);
INSERT INTO t1 VALUES(15416);
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
USE test;
SET SESSION aria_sort_buffer_size=CAST(-1 AS UNSIGNED INT);
INSERT INTO t1 VALUES('C'),('c');
INSERT INTO t1 VALUES(1550);
SET SESSION aria_repair_threads=CAST(-1 AS UNSIGNED INT);
INSERT INTO t1 VALUES('2001-01-01 00:00:01.000000');
INSERT INTO t1 VALUES('a');
INSERT INTO t1 VALUES(1),(3);
INSERT INTO t1 VALUES(0xACD4);
INSERT INTO t1 VALUES(0xABA8);
INSERT INTO t1 VALUES(1);
INSERT INTO t1 VALUES(0xF48F8080);
DELETE FROM mysql.user WHERE USER='mysqltest_4';
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES(0xA9A2);
INSERT t1 VALUES(30),(1230),("1230"),("12:30"),("12:30:35"),("1 12:30:31.32");
INSERT INTO t1 VALUES("19991101000000"),("19990102030405"),("19990630232922"),("19990601000000");
INSERT INTO t1 VALUES('2004-01-01'),('2004-02-29');
INSERT INTO t1 VALUES('2001-01-01 10:10:10.999993');
INSERT INTO t1 VALUES(0xADE5);
INSERT INTO t1 VALUES('');
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES('a');
INSERT INTO t1 VALUES('Z');
SET SESSION tmp_table_size=65535;
INSERT INTO t1 VALUES(12704);
INSERT INTO t1 VALUES('0.1');
INSERT INTO t1 VALUES('698aaaaaaaaaaaaaaaaaaaaaaaaaa');
INSERT INTO t1 VALUES(0xA9AA);
INSERT INTO t1 VALUES(unhex (hex (132)));
INSERT INTO t1 VALUES(1),(2),(1),(2),(1),(2),(3);
INSERT IGNORE INTO t1 VALUES(@inserted_value);
INSERT INTO t1 VALUES(15416);
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
CREATE TABLE t1 (a VARCHAR(255));
INSERT INTO t1 VALUES('C'),('c');
XA BEGIN 'a','ab';
INSERT INTO t1 VALUES('2001-01-01 00:00:01.000000'),('a'),(1),(3),(0xACD4),(0xABA8),(1),(0xF48F8080);
INSERT INTO t1 SELECT * FROM t1;

SET SESSION aria_sort_buffer_size=18446744073709551615;
SET SESSION aria_repair_threads=18446744073709551615;
CREATE TABLE t1 (a VARCHAR(255));
INSERT INTO t1 VALUES('C'), ('c');
XA BEGIN 'a','ab';
INSERT INTO t1 VALUES('2001-01-01 00:00:01.000000'),('a'),(1),(3),(0xACD4),(0xABA8),(1),(0xF48F8080);
#DELETE FROM mysql.user WHERE USER='mysqltest_4';
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES(0xA9A2);
INSERT t1 VALUES(30), (1230), ("1230"), ("12:30"), ("12:30:35"), ("1 12:30:31.32");
INSERT INTO t1 VALUES("19991101000000"), ("19990102030405"), ("19990630232922"), ("19990601000000");
INSERT INTO t1 VALUES('2004-01-01'), ('2004-02-29');
INSERT INTO t1 VALUES('2001-01-01 10:10:10.999993');
INSERT INTO t1 VALUES(0xADE5);
INSERT INTO t1 VALUES('');
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES('a');
INSERT INTO t1 VALUES('Z');
SET SESSION tmp_table_size=65535;
INSERT INTO t1 VALUES(12704);
INSERT INTO t1 VALUES('0.1');
INSERT INTO t1 VALUES('698aaaaaaaaaaaaaaaaaaaaaaaaaa');
INSERT INTO t1 VALUES(0xA9AA);
INSERT INTO t1 VALUES(unhex (hex (132)));
INSERT INTO t1 VALUES(1), (2), (1), (2), (1), (2), (3);
INSERT IGNORE INTO t1 VALUES(@inserted_value);
INSERT INTO t1 VALUES(15416);
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
USE test;
SET SESSION aria_sort_buffer_size=CAST(-1 AS UNSIGNED INT);
INSERT INTO t1 VALUES('C'), ('c');
INSERT INTO t1 VALUES(1550);
SET SESSION aria_repair_threads=CAST(-1 AS UNSIGNED INT);
INSERT INTO t1 VALUES('2001-01-01 00:00:01.000000');
INSERT INTO t1 VALUES('a');
INSERT INTO t1 VALUES(1), (3);
INSERT INTO t1 VALUES(0xACD4);
INSERT INTO t1 VALUES(0xABA8);
INSERT INTO t1 VALUES(1);
INSERT INTO t1 VALUES(0xF48F8080);
DELETE FROM mysql.user WHERE USER='mysqltest_4';
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES(0xA9A2);
INSERT t1 VALUES(30), (1230), ("1230"), ("12:30"), ("12:30:35"), ("1 12:30:31.32");
INSERT INTO t1 VALUES("19991101000000"), ("19990102030405"), ("19990630232922"), ("19990601000000");
INSERT INTO t1 VALUES('2004-01-01'), ('2004-02-29');
INSERT INTO t1 VALUES('2001-01-01 10:10:10.999993');
INSERT INTO t1 VALUES(0xADE5);
INSERT INTO t1 VALUES('');
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES('a');
INSERT INTO t1 VALUES('Z');
SET SESSION tmp_table_size=65535;
INSERT INTO t1 VALUES(12704);
INSERT INTO t1 VALUES('0.1');
INSERT INTO t1 VALUES('698aaaaaaaaaaaaaaaaaaaaaaaaaa');
INSERT INTO t1 VALUES(0xA9AA);
INSERT INTO t1 VALUES(unhex (hex (132)));
INSERT INTO t1 VALUES(1), (2), (1), (2), (1), (2), (3);
INSERT IGNORE INTO t1 VALUES(@inserted_value);
INSERT INTO t1 VALUES(15416);
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));

DROP DATABASE test;
CREATE DATABASE test;
USE test;
SET SESSION aria_repair_threads=CAST(-1 AS UNSIGNED INT);
SET SESSION aria_sort_buffer_size=CAST(-1 AS UNSIGNED INT);
SET SESSION tmp_table_size=65535;
CREATE TABLE t1 (a BIT(7));
INSERT INTO t1 VALUES('C'), ('c');
ALTER TABLE t1 modify a VARCHAR(255);
XA BEGIN 'a';
INSERT INTO t1 VALUES('2001-01-01 00:00:01.000000');
INSERT INTO t1 VALUES('a');
INSERT INTO t1 VALUES(1), (3);
INSERT INTO t1 VALUES(0xACD4);
INSERT INTO t1 VALUES(0xABA8);
INSERT INTO t1 VALUES(1);
INSERT INTO t1 VALUES(0xF48F8080);
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES(0xA9A2);
INSERT t1 VALUES(30), (1230), ("1230"), ("12:30"), ("12:30:35"), ("1 12:30:31.32");
INSERT INTO t1 VALUES("19991101000000"), ("19990102030405"), ("19990630232922"), ("19990601000000");
INSERT INTO t1 VALUES('2004-01-01'), ('2004-02-29');
INSERT INTO t1 SELECT 1 FROM t1;
INSERT INTO t1 VALUES('2001-01-01 10:10:10.999993');
INSERT INTO t1 VALUES(0xADE5);
INSERT INTO t1 VALUES('');
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES('a');
INSERT INTO t1 VALUES('Z');
INSERT INTO t1 VALUES(12704);
INSERT INTO t1 VALUES('0.1');
INSERT INTO t1 VALUES('698aaaaaaaaaaaaaaaaaaaaaaaaaa');
INSERT INTO t1 VALUES(0xA9AA);
INSERT INTO t1 VALUES(unhex (hex (132)));
INSERT INTO t1 VALUES(1), (2), (1), (2), (1), (2), (3);
INSERT IGNORE INTO t1 VALUES(@inserted_value);
INSERT INTO t1 VALUES(15416);
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
INSERT INTO t1 VALUES('C'), ('c');
INSERT INTO t1 VALUES(1550);
INSERT INTO t1 VALUES('2001-01-01 00:00:01.000000');
INSERT INTO t1 VALUES('a');
INSERT INTO t1 VALUES(1), (3);
INSERT INTO t1 VALUES(0xACD4);
INSERT INTO t1 VALUES(0xABA8);
INSERT INTO t1 VALUES(1);
INSERT INTO t1 VALUES(0xF48F8080);
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES(0xA9A2);
INSERT t1 VALUES(30), (1230), ("1230"), ("12:30"), ("12:30:35"), ("1 12:30:31.32");
INSERT INTO t1 VALUES("19991101000000"), ("19990102030405"), ("19990630232922"), ("19990601000000");
INSERT INTO t1 VALUES('2004-01-01'), ('2004-02-29');
INSERT INTO t1 VALUES('2001-01-01 10:10:10.999993');
INSERT INTO t1 VALUES(0xADE5);
INSERT INTO t1 VALUES('');
INSERT INTO t1 SELECT * FROM t1;
INSERT INTO t1 VALUES('a');
INSERT INTO t1 VALUES('Z');
INSERT INTO t1 VALUES(12704);
INSERT INTO t1 VALUES('0.1');
INSERT INTO t1 VALUES('698aaaaaaaaaaaaaaaaaaaaaaaaaa');
INSERT INTO t1 VALUES(0xA9AA);
INSERT INTO t1 VALUES(unhex (hex (132)));
INSERT INTO t1 VALUES(1), (2), (1), (2), (1), (2), (3);
INSERT IGNORE INTO t1 VALUES(@inserted_value);
INSERT INTO t1 VALUES(15416);
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
UPDATE t1 SET a=( (SELECT MAX(a) FROM t1));
XA END 'a';
USE test;
