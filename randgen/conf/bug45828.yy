query:
	SELECT field_list
	FROM _table
	WHERE predicate_list
	order_by_group_by
	limit;

field_list:
	* | _field ;

predicate_list:
	predicate AND predicate ;

predicate:
	( _field_key sign value ) |
	( _field_key BETWEEN _digit AND _digit ) |
	( _field_key BETWEEN _tinyint AND _tinyint ) |
	( _field_key BETWEEN _integer AND _integer )
# |
#	( _field_key IN ( value_list ) ) 
;

value_list:
	value | 
	value , value_list ;

value:
	_digit | _tinyint_unsigned | integer_unsigned ;

order_by_group_by:
	ORDER BY _field_key |
	GROUP BY _field_key ;
limit:
	| LIMIT 1 | LIMIT _digit | LIMIT _tinyint_unsigned | LIMIT _integer_unsigned ;

sign:
	= | > | < ;
