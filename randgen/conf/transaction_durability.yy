query:
	lock ; START TRANSACTION ; dml ; dml ; SAVEPOINT A ; dml ; dml ; ROLLBACK TO SAVEPOINT A ; dml ; dml ; commit_rollback ; unlock ;

lock:
	SELECT GET_LOCK('LOCK', 65535) ;

unlock:
	SELECT RELEASE_LOCK('LOCK') ;

commit_rollback:
	COMMIT | ROLLBACK ;

dml:
	insert | update ;
#| delete ;

where:
	WHERE _field sign value ;
#	WHERE _field BETWEEN value AND value ;

sign:
	= | > | < | = | >= | <> | <= | != ;

insert:
	INSERT INTO _table ( _field , _field ) VALUES ( value , value ) ;

update:
	UPDATE _table AS X SET _field = value , _field = value , _field = value where ;

delete:
	DELETE FROM _table WHERE _field = value ;

value:
	_tinyint_unsigned ;

_field:
	`col_int_key` | `col_int_nokey` ;

# | _english | _digit | _date | _datetime | _time ;
