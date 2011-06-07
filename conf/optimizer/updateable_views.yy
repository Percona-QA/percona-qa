query:
	select | insert | delete | update |
	select | insert | delete | update |
	select | insert | delete | update |
	select | insert | delete | update |
	create | drop ;

create:
	CREATE ALGORITHM = algorithm VIEW view_name AS select check_option ;

drop:
	DROP VIEW view_name ;

select:
	SELECT field1 , field2 , field3 , field4 FROM table_view_name where ;

insert:
	insert_single | insert_multi | insert_select ;

insert_single:
	insert_replace INTO view_name SET value_list ;

insert_multi:
	insert_replace INTO view_name VALUES row_list ;

insert_select:
	insert_replace INTO view_name select ;

update:
	UPDATE view_name SET value_list where |
	UPDATE view_name SET value_list where ORDER BY field1 , field2 , field3, field4 LIMIT _digit ;

delete:
	DELETE FROM view_name where ORDER BY field1 , field2 , field3 , field4 LIMIT _digit ;

insert_replace:
	INSERT | REPLACE ;


value_list:
	value_list , value_item |
	value_item , value_item ;

row_list:
	row_list , row_item |
	row_item , row_item ;

row_item:
	( value , value , value , value );

value_item:
	field_name = value ;

table_view_name:
	table_name | table_name | view_name ;

where:
	|
	WHERE field_name cmp_op value ;

field_name:
	field1 | field2 | field3 | field4 ;

value:
	_digit | _tinyint_unsigned | _varchar(1) | _english | NULL ;

cmp_op:
	= | > | < | >= | <= | <> | != | <=> ;

check_option:
	| | | | ;
#	WITH cascaded_local CHECK OPTION ;

cascaded_local:
	CASCADED | LOCAL ;

table_name:
	table_merge | table_merge_child | table_multipart | table_partitioned | table_standard | table_virtual ;

view_name:
	view1 | view2 | view3 | view4 | view5 ;

algorithm:
	MERGE | MERGE | MERGE | MERGE | MERGE |
	MERGE | MERGE | MERGE | TEMPTABLE | UNDEFINED ;
