CREATE TABLE t (i INT AUTO_INCREMENT PRIMARY KEY);
DELETE FROM t WHERE i IN (SELECT JSON_OBJECT('a','a') FROM DUAL WHERE 1);

create table t1 (a int );
insert into t1 values (1),(2),(3);
update t1 set a = 2 where a in (select a where a = a);

select 1 from dual where 1 in (select 5 where 1);

CREATE TABLE v0 ( v1 INT ) ;
INSERT INTO v0 ( v1 ) VALUES ( 9 ) ;
UPDATE v0 SET v1 = 2 WHERE v1 IN ( SELECT v1 WHERE v1 = v1 OR ( v1 = -1 AND v1 = 28 ) ) ;
INSERT INTO v0 ( v1 ) VALUES ( 60 ) , ( 0 ) ;
SELECT RANK ( v1 ) OVER w , STD ( v1 ) OVER w FROM v0 WINDOW v2 AS ( PARTITION BY v1 ORDER BY v1 * 0 ) ;
