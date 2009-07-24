query:
	insert | update | insert | delete | select;

insert:
	INSERT INTO _table ( _field , _field ) VALUES ( value , value );

select:
	SELECT _field FROM _table WHERE condition order_by ;

update:
 	UPDATE _table SET _field = digit WHERE condition order_by ;

delete:
	DELETE FROM _table WHERE condition LIMIT 1 ;

condition:
	_field IN ( value , value , value , value , value , value , value , value , value , value , value ) |
	_field sign value | _field sign value |
	_field BETWEEN value AND value |
	_field LIKE CONCAT( LEFT( value , _digit ) , '%' ) ;

sign:
	= | < | > | <> | <=> | != | >= | <= ;

value:
	_varchar(255);

order_by:
	|
	ORDER BY _field , _field ;
