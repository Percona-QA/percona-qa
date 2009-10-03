query:
	{ @nonaggregates = () ; $tables = 0 ; $fields = 0 ; "" } select ;

select:
	SELECT select_list
	FROM join_list
	where
	group_by
	having
	order_by_limit
;

select_list:
	new_select_item |
	new_select_item , select_list ;

join_list:
	new_table_item |
	(new_table_item join_type new_table_item ON ( current_table_item . _field_key = previous_table_item . _field )) |
	(new_table_item join_type new_table_item ON ( current_table_item . _field = previous_table_item . _field_key )) |
	(new_table_item join_type new_table_item ON ( current_table_item . _field_key = previous_table_item . _field_key )) |
	(new_table_item join_type join_list ON ( current_table_item . _field_key = previous_table_item . _field_key ));

join_type:
	INNER JOIN | left_right outer JOIN | STRAIGHT_JOIN ;  

left_right:
	LEFT | RIGHT ;

outer:
	| OUTER ;
where:
	WHERE where_list ;

where_list:
	not where_item |
	not (where_list AND where_item) |
	not (where_list OR where_item) ;

not:
	| | | NOT;

where_item:
	existing_table_item . _field sign value |
	existing_table_item . _field sign existing_table_item . _field ;

group_by:
	{ scalar(@nonaggregates) > 0 ? " GROUP BY ".join (', ' , @nonaggregates ) : "" };

having:
	| HAVING having_list;

having_list:
	not having_item |
	not (having_list AND having_item) |
	not (having_list OR having_item) |
	having_item IS not NULL ;

having_item:
	existing_select_item sign value ;

order_by_limit:
	|
	ORDER BY order_by_list |
	ORDER BY order_by_list , total_order_by LIMIT _digit ;

total_order_by:
	{ join(', ', map { "field".$_ } (1..$fields) ) };

order_by_list:
	order_by_item |
	order_by_item , order_by_list ;

order_by_item:
	existing_select_item;

limit:
	| LIMIT _digit | LIMIT _digit OFFSET _digit;

new_select_item:
	nonaggregate_select_item |
	nonaggregate_select_item |
	aggregate_select_item;

nonaggregate_select_item:
	table_one_two . _field AS { my $f = "field".++$fields ; push @nonaggregates , $f ; $f} ;

aggregate_select_item:
	aggregate table_one_two . _field ) AS { "field".++$fields };

# Only 20% table2, since sometimes table2 is not present at all

table_one_two:
	table1 | table1 | table1 | table1 |
	table2 ;

aggregate:
	COUNT( | SUM( | MIN( | MAX( ;

new_table_item:
	_table AS { "table".++$tables };

current_table_item:
	{ "table".$tables };

previous_table_item:
	{ "table".($tables - 1) };

existing_table_item:
	{ "table".$prng->int(1,$tables) };

existing_select_item:
	{ "field".$prng->int(1,$fields) };

sign:
	= | > | < | != | <> | <= | >= ;
	
value:
	_digit | _char(2) | _datetime ;

# Avoid A , AA since those tables are optimized away
# Avoid E, F since those tables are too big for the nested joins

_table:
	B | C | BB | CC ;

# Avoid 0, so that no LIMIT 0 queries are produced

_digit:
	1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 ;

