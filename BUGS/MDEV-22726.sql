ALTER TABLE mysql.general_log ENGINE=Aria;
SET GLOBAL log_output='TABLE';
SET GLOBAL general_log=TRUE;
SET SESSION OPTIMIZER_SWITCH="derived_merge=OFF";
