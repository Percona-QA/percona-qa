SET SESSION optimizer_switch="derived_merge=OFF";
CREATE TABLE t (c INT PRIMARY KEY) ENGINE=InnoDB;
PREPARE s FROM 'INSERT INTO t SELECT * FROM (SELECT * FROM t) AS a';
SET SESSION optimizer_switch="derived_merge=ON";
EXECUTE s;
