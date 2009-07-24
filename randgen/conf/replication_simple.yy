query:
 	update | insert | delete ;

update:
 	UPDATE _table SET _field = digit WHERE condition ;

delete:
	DELETE FROM _table WHERE condition ;

insert:
	INSERT INTO _table ( _field ) VALUES ( value ) ;

condition:
 	_field = value |
	_field > value AND _field < value ;

value:
	_digit | _char(255) | _english | _datetime | NULL ;
