create table t1 ( a2 time not null, a1 varchar(1) not null) engine=myisam;
create table t2 ( i1 int not null, i2 int not null) engine=myisam;
insert into t2 values (0,0);
select 1 from t2 where (i1, i2) in (select count((a1 div '1')), bit_or(a2) over () from t1);
