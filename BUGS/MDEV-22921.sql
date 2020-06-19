# mysqld options required for replay: --log-bin 
RESET MASTER TO 0x7FFFFFFF;
SET @@GLOBAL.binlog_checksum=NONE;

# mysqld options required for replay: --log-bin 
SET @@GLOBAL.OPTIMIZER_SWITCH="orderby_uses_equalities=ON";
RESET MASTER TO 0x7FFFFFFF;
SET @@GLOBAL.binlog_checksum=NONE;
