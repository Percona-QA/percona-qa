query:
 	update | insert | delete ;

update:
 	UPDATE _table SET _field = digit WHERE condition LIMIT _digit ;

delete:
	DELETE FROM _table WHERE condition LIMIT _digit ;

insert:
	INSERT INTO _table ( _field ) VALUES ( _digit ) ;

condition:
 	_field < digit | _field = _digit ;
