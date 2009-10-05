query:
 	select | update | insert | delete ;

select:
	SELECT _field FROM _table WHERE condition LIMIT _digit ;

update:
 	UPDATE _table SET _field = digit WHERE condition LIMIT _digit ;

delete:
	DELETE FROM _table WHERE condition LIMIT _digit ;

insert:
	INSERT INTO _table ( _field ) VALUES ( _digit ) ;

condition:
 	_field < digit | _field = _digit ;
