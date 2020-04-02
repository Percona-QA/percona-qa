SET @cmd:="SET @@SESSION.SQL_MODE=(SELECT 'a')";
SET @@SESSION.OPTIMIZER_SWITCH="materialization=OFF";
SET @@SESSION.OPTIMIZER_SWITCH="in_to_exists=OFF";
PREPARE stmt FROM @cmd;

SET @cmd:="SET @x=(SELECT 'a')";
SET @@SESSION.OPTIMIZER_SWITCH="materialization=OFF,in_to_exists=OFF";
PREPARE stmt FROM @cmd;
