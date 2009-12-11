## TODO: Re-enable UTF16 in 'charset' and _UTF16 in 'charset_underscore' once WL#1213 is pushed.
##       (Implementation not present in current 6.0 or 5.x codebases).

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
	CONVERT( string USING charset ) |
	REPEAT( charset_underscore _hex , _tinyint_unsigned );

string:
	_english | _varchar(255);

charset:
	UTF8 | LATIN1 | ASCII | UCS2 ;

charset_underscore:
	_UTF8 | _LATIN1 | _ASCII | _UCS2 ;

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
