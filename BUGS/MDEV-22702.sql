create table t1 (a1 int, a2 decimal(10,0) not null) engine=myisam;
select min(1 mod a1), bit_or(a2) over () from t1;
