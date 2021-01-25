SET optimizer_switch='derived_merge=off';
CREATE TABLE t (a INT) ENGINE=InnoDB;
PREPARE s FROM 'SELECT * FROM (SELECT * FROM t) AS d';
EXECUTE s;
SET optimizer_switch='default';
SET big_tables='on';
EXECUTE s;
