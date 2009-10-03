query:
 	update | insert | delete | select ;

select:
	SELECT _field FROM _table ;

update:
 	UPDATE _table SET _field_no_pk = value WHERE condition update_scope;

update_scope:
	|
	ORDER BY `pk` LIMIT _digit ;

delete:
	DELETE FROM _table WHERE condition ORDER BY `pk` LIMIT 1 ;

insert:
	INSERT INTO _table ( _field , _field , _field ) VALUES ( value , value , value ) ;

value:
	CONVERT( string , CHAR) |
	REPEAT( _hex , _tinyint_unsigned );

string:
	_english | _varchar(255);

condition:
	_field operator value |
	_field BETWEEN value AND value |
	_field IN ( value , value , value , value , value , value , value ) |
	_field LIKE CONCAT( value , '%' ) |
	_field IS not NULL ;

not:
	| NOT ;

operator:
	< | > | = | <> | != | <= | >= ;
