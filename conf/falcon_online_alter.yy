query:
	update | insert | select | alter | transaction ;

select:
	SELECT _field FROM _table WHERE where_cond group_by limit;

group_by:
	| GROUP BY _field ;

limit:
	| LIMIT digit ;

where_cond:
	_field < digit;

insert:
	INSERT INTO _table ( _field , _field ) VALUES ( digit , digit ) ;

update:
#	UPDATE _table SET _field = digit WHERE where_cond limit 
;

delete:
	DELETE FROM _field WHERE where_cond LIMIT digit;

transaction:
	START TRANSACTION | COMMIT | ROLLBACK;

alter:
	ALTER online TABLE _table key_def , key_def |
	ALTER online TABLE _table DROP KEY letter ;

online:
	 ;

key_def:
	ADD key_type letter ( _field , _field );

key_type:
	KEY | UNIQUE | PRIMARY KEY ;
