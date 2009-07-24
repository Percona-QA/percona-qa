query:
 	update | insert | delete ;

#
# We take one inital backup before we have started messing up with the tables.
# We will then restore from this known-good backup periodically in order to prevent a situation where
# the tables are obliterated from a failed RESTORE and the test just continues to run with no tables
#
thread1_init:
	BACKUP DATABASE test TO ' master_backup ' ;

thread1:
	backup_restore | backup_restore | backup_restore | backup_restore |
	restore_master;

backup_restore:
	SELECT SLEEP(1) ; BACKUP DATABASE test TO _tmpnam ; SELECT SLEEP(1) ; RESTORE FROM _tmpnam OVERWRITE ;

restore_master:
	SELECT SLEEP(1) ; RESTORE FROM ' master_backup ' OVERWRITE ;

update:
 	UPDATE _table SET _field = digit WHERE condition LIMIT _digit ;

delete:
	DELETE FROM _table WHERE condition LIMIT 1 ;

insert:
	INSERT INTO _table ( _field ) VALUES ( _digit ) |
	INSERT INTO _table ( _field ) SELECT _field FROM _table LIMIT _digit ;

condition:
 	_field < digit | _field = _digit ;
