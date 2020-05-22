create table t1 (pk int primary key, a int, b int, filler char(32), key (a), key (b)) engine=myisam  partition by range(pk) (partition p0 values less than (10), partition p1 values less than MAXVALUE);
insert into t1 select seq, MOD(seq, 100), MOD(seq, 100), 'filler-data-filler-data' from seq_1_to_50000;
explain select * from t1 partition (p1) where a=10 and b=10; 
flush tables;
select * from t1 partition (p1)where a=10 and b=10;
