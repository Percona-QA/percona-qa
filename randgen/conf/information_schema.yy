query_init:
        SET GLOBAL optimizer_use_mrr = 'disable';

query:
	{ @nonaggregates = () ; @table_names = () ; @database_names = () ; $tables = 0 ; $fields = 0 ; "" } select ;

select:
	SELECT *
#select_list
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
	(new_table_item join_type new_table_item ON ( current_table_item . _field = previous_table_item . _field ) ) ;

join_type:
	INNER JOIN | left_right outer JOIN | STRAIGHT_JOIN ;  

left_right:
	LEFT | RIGHT ;

outer:
	| OUTER ;
where:
	WHERE where_list ;

where_list:
	not where_item ;
# |
#	not (where_list AND where_item) |
#	not (where_list OR where_item) ;

not:
	| | | NOT;

where_item:
#	existing_table_item . _field sign value |
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
	existing_table_item . _field sign value ;

order_by_limit:
	|
	ORDER BY order_by_list |
	ORDER BY order_by_list LIMIT _digit ;

total_order_by:
	{ join(', ', map { "field".$_ } (1..$fields) ) };

order_by_list:
	order_by_item |
	order_by_item , order_by_list ;

order_by_item:
	existing_table_item . _field ;

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
	table1 { $last_table = $tables[1] } | 
	table2 { $last_table = $tables[2] } ;

aggregate:
	COUNT( | SUM( | MIN( | MAX( ;

new_table_item:
	_database . _table AS { $database_names[++$tables] = $last_database ; $table_names[$tables] = $last_table ; "table".$tables };

current_table_item:
	{ $last_database = $database_names[$tables] ; $last_table = $table_names[$tables] ; "table".$tables };

previous_table_item:
	{ $last_database = $database_names[$tables-1] ; $last_table = $table_names[$tables-1] ; "table".($tables - 1) };

existing_table_item:
	{ my $i = $prng->int(1,$tables) ; $last_database = $database_names[$i]; $last_table = $table_names[$i] ; "table".$i };

existing_select_item:
	{ "field".$prng->int(1,$fields) };

sign:
	= | > | < | != | <> | <= | >= ;
	
value:
	_digit | _char(2) | _datetime ;
