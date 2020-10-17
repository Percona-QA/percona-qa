use test;
create table t1 (a int) ;
delimiter $$
create procedure t1_data()
begin
  declare i int default 1;
  while i < 1000 do insert into t1 values (i); set i = i + 1;
  end while;
end$$
delimiter ;
call t1_data();
create procedure sp() select * from (select a from t1) tb;
call sp();
set optimizer_switch='derived_merge=off';
call sp();

USE test;
CREATE TABLE t AS SELECT {d'2001-01-01'},{d'2001-01-01 10:10:10'};
PREPARE p FROM "SELECT p.* FROM (SELECT t.* FROM t AS t) AS p";
EXECUTE p;
SET @@SESSION.OPTIMIZER_SWITCH="derived_merge=OFF";
EXECUTE p;

USE test;
CREATE TABLE t (a INT PRIMARY KEY);
PREPARE s FROM "SELECT a.* FROM (SELECT tt.* FROM t tt) AS a";
EXECUTE s;
SET SESSION optimizer_switch="derived_merge=OFF";
EXECUTE s;
