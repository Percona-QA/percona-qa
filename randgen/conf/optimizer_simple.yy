\query_init:
        SET GLOBAL optimizer_use_mrr = 'disable';

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
	(new_table_item join_type join_list ON ( current_table_item . _field = previous_table_item . _field ));

join_type:
	INNER JOIN | CROSS JOIN | left_right outer JOIN | STRAIGHT_JOIN ;  

left_right:
	LEFT | RIGHT ;

outer:
	| OUTER ;
where:
	WHERE where_list ;

where_list:
	not where_item |
	not (where_list AND where_item) |
	not (where_list OR where_item) |
	where_item IS not NULL ;
not:
	| NOT;

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
	ORDER BY order_by_list order_direction |
	ORDER BY order_by_list order_direction, total_order_by LIMIT _digit |
        ORDER BY ;

order_direction:
        |
        DESC ;

total_order_by:
	{ join(', ', map { "field".$_ } (1..$fields) ) };

order_by_list:
	order_by_item |
	order_by_item , order_by_list ;

order_by_item:
	existing_select_item ;

limit:
	| LIMIT _digit | LIMIT _digit OFFSET _digit;

new_select_item:
	nonaggregate_select_item |
	nonaggregate_select_item |
	aggregate_select_item;

nonaggregate_select_item:
	table_one_two . _field AS { my $f = "field".++$fields ; push @nonaggregates , $f ; $f} |
        table_one_two . _field_indexed AS { my $f = "field".++$fields ; push @nonaggregates, $f ; $f} |
        table_one_two . * ;

aggregate_select_item:
	aggregate table_one_two . _field ) AS { "field".++$fields };

table_one_two:
	table1 | table2 | table3;

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

_table:
	A | B | C | AA | BB ;
