USE test;
CREATE TABLE t(a INT);
INSERT INTO t VALUES(0);
INSERT INTO t SELECT a FROM t LIMIT ROWS EXAMINED 0;

create table t1 (id int not null auto_increment primary key,k int, c char(20));
insert into t1 (k,c) values (0,'0'), (0,'0'),(0,'0'),(0,'0'),(0,'0'),(0,'0'),(0,'0');
insert into t1 (c) select k from t1 limit rows examined 2;
