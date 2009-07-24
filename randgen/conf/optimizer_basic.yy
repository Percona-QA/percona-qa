query:
      {@nonaggregates = () ; $tables = 0 ; $fields = 0; "" } main_query ;

main_query:
      SELECT straight_join select_type
      FROM table_list
      where_clause
      group_by_clause
      having_clause
      order_clause;

straight_join:
           | STRAIGHT_JOIN ; 

select_type:
     rand_select_list | rand_select_list ;

rand_select_list:
      rand_select_item |
      rand_select_item , rand_select_list |
      rand_select_item , rand_select_list ;
      
rand_select_item:
      x_y . field_name AS {my $f = "field".++$fields ; push @nonaggregates , $f ; $f } |
      x_y . field_name AS {my $f = "field".++$fields ; push @nonaggregates , $f ; $f } |
      x_y . field_name AS {my $f = "field".++$fields ; push @nonaggregates , $f ; $f } | 
      aggregate_function x_y . field_name ) |
      x_y . field_name AS {my $f = "field".++$fields ; push @nonaggregates , $f ; $f } |
      x_y . field_name AS {my $f = "field".++$fields ; push @nonaggregates , $f ; $f } |
      x_y . field_name AS {my $f = "field".++$fields ; push @nonaggregates , $f ; $f } |
      aggregate_function x_y . field_name ) |
      x_y . * ;

inner_cross:
      INNER | CROSS ;

left_right:
      LEFT  | RIGHT ;

outer:
      | OUTER ;

opt_join_condition:
        | join_condition ;

join_condition:
     ON  join_expr ;

join_expr:
    ( X . field_name arithmetic_operator Y . field_name ) ;


table_list:
      table_item   X , table_item   Y |
      table_item   X inner_cross JOIN table_item   Y |
      table_item   X STRAIGHT_JOIN table_item   Y opt_join_condition |
      table_item   X left_right outer JOIN table_item  Y join_condition |
      table_item   X NATURAL left_right outer JOIN table_item  Y ;

table_item:
      B | C | BB | CC | BBB | CCC ;

where_clause:
      | WHERE where_list | WHERE where_list;

where_list:
      where_condition |
      ( where_condition ) logical_operator where_list ;

where_condition:
      x_y . field_name arithmetic_operator x_y . field_name |
      x_y . field_name arithmetic_operator x_y . field_name |
      x_y . field_name arithmetic_operator value ;

x_y:     X | Y ; 

group_by_clause: 
         { scalar(@nonaggregates) > 0 ? " GROUP BY ".join(', ' , @nonaggregates ) : "" } ;
         

having_clause: 
        | HAVING having_list ;

having_list: 
        not having_item |
        not having_item |
        not (having_list logical_operator having_item) |
        existing_select_item null_operator ;

having_item:
       ( existing_select_item arithmetic_operator digit ) |
       ( existing_select_item arithmetic_operator existing_select_item );

not:
   NOT | | |;

existing_select_item:
   { "field".$prng->int(1,$fields) } ;

order_clause:
         | 
         ORDER BY order_list desc |
         ORDER BY order_list desc limit | 
         ORDER BY total_order_by desc limit  ;

order_list:
         order_by_item | 
         order_by_item , order_list ;

order_by_item:
         x_y . _field | existing_select_item ;

total_order_by:
         { join(', ', map { "field".$_ } (1..$fields) ) } ;

desc:
    ASC | | DESC ;

digit:
    1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 20 ;

limit:
    LIMIT digit | LIMIT digit | | | | LIMIT digit OFFSET digit ;


aggregate_function:
         AVG( |
         COUNT(DISTINCT | COUNT( |
         MIN( | MIN(DISTINCT | 
         MAX( | MAX(DISTINCT |
         SUM( | SUM(DISTINCT ;

arithmetic_operator:
	= | > | < | <> | >= | <= ;

logical_operator:
	AND | OR | OR NOT | AND NOT ;

null_operator: IS NULL | IS NOT NULL | IS NOT NULL ;

field_name:
        int_field_name ;

int_field_name:
        `pk` | `int_key` | `int_nokey` ;

value:
        _digit ; 
