query:
	create_select | create_select | create_select | drop_table |
	insert_select | insert_select | insert_select | truncate_table ;

create_select:
	CREATE TABLE _letter SELECT * FROM table_name ;

insert_select:
	INSERT INTO _letter SELECT * FROM table_name ;

drop_table:
	DROP TABLE _letter ;

truncate_table:
	TRUNCATE TABLE _letter ;

table_name:
	_letter | _table ;
