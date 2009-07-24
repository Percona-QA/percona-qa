query:
	transaction |
	dml | dml | dml | dml | dml | dml | dml | dml |
	dml | dml | dml | dml |	dml | dml | dml | dml |
	dml | dml | dml | dml |	dml | dml | dml | dml |
	dml | dml | dml | dml |	dml | dml | dml | dml |
	dml | dml | dml | dml ;

dml:
	update | insert | select;

where_cond_2:
	X . _field < value | X . _field > value;

where_cond_1:
	_field < value | _field > value ;

select:
	SELECT * FROM _table WHERE where_cond_1 ;

insert:
	INSERT INTO _table ( _field , _field ) VALUES ( value , value ) ;

update:
	UPDATE _table AS X SET _field = value WHERE where_cond_2 ;

transaction:
	START TRANSACTION | COMMIT | ROLLBACK ;

value:
	_char(255) | _bigint ;
