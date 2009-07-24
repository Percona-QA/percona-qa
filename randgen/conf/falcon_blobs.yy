query_init:
	START TRANSACTION ;

query:
 	update | insert | delete ;

update:
 	UPDATE _table SET _field_no_pk = value WHERE condition LIMIT 1 ;

delete:
	DELETE FROM _table WHERE condition LIMIT 1 ;

insert:
	INSERT INTO _table ( _field ) VALUES ( value ) ;

condition:
	pk = _digit ;

value:
	_data | _varchar(1024) ;
