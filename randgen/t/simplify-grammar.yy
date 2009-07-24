query:
 	select | update | insert | delete ;

select:
	SELECT select_items FROM _table where group_by order_by limit;

limit:
	| LIMIT _digit ;

order_by:
	| ORDER BY _field ;

where:
	| WHERE condition ;

group_by:
	| GROUP BY _field ;

select_items:
	select_item |
	select_items , select_item ;

select_item:
	S1 | S2 | S3 ;

update:
 	UPDATE _table SET _field = digit where limit ;

delete:
	DELETE FROM _table WHERE condition limit ;

insert:
	INSERT INTO _table ( _field ) VALUES ( _digit ) ;

condition:
 	cond_item < digit | cond_item = _digit ;

cond_item:
	C1 | C2 | C3 ;

_field:
	F1 | F2 | F3 ;

_table:
	AA | BB | CC ;
