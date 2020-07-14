CREATE TABLE t1 (k1 varchar(10) DEFAULT 5);
CREATE TABLE t2 (i1 int);
ALTER TABLE t1 ALTER COLUMN k1 SET DEFAULT (SELECT 1 FROM t2 limit 1);

CREATE TABLE t1 (k1 text DEFAULT 4);
CREATE TABLE t2 (i1 int);
ALTER TABLE t1 ALTER COLUMN k1 SET DEFAULT (SELECT i1 FROM t2 WHERE i1 = 4 limit 1) ;

create table t1 (k1 varchar(10) default 5);
insert into t1 values (1),(2);
create table t2 (i1 int);
insert into t2 values (1),(2);
alter table t1 alter column k1 set default (select i1 from t2 where i1=2);

create table t1 (i int); #optional
create table t2 (i int); #optional
ALTER TABLE t1 PARTITION BY system_time INTERVAL (SELECT i FROM t2) DAY (PARTITION p1 HISTORY, PARTITION pn CURRENT) ;
