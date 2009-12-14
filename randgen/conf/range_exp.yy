query:
  { @idx_tables = () ; $tables = 0 ; $fields = 0 ; @idx_fields = () ; @idx_select_fields = () ; "" } new_index ; query_set ;

query_set:
  query_type ; query_type ; query_type | 
  query_type ; query_type ; query_type | 
  query_type ; query_set ;


query_type:
   { $tables = 0 ; $fields = 0 ; "" } query_version ;

query_version: 
   select_query | select_query | select_query | select_query | select_query ;  

select_query:
   tame_query | wild_query ;

tame_query:
   tame_int_select ;

################################################################################
# index-specific rules
################################################################################
new_index:
 { scalar(@idx_tables) > 0 ? " DROP INDEX `test_idx` ON ".join(' ', @idx_tables )." ;" : "" ; @idx_tables = () ; "" } new_index_type ;

new_index_type:
  new_int_index ;

new_int_index:
 ALTER TABLE index_table ADD INDEX `test_idx` USING index_type (int_idx_field_list) ;

int_idx_field_list:
  `pk` { @idx_fields =("`col_int_key`") ; @idx_select_fields=("table1 . `col_int_key` AS idx_field1") ; "" }| 
  `col_int_key`  { @idx_fields =("`col_int_key`") ; @idx_select_fields=("table1 . `col_int_key` AS idx_field1") ; "" } | 
  `col_int_nokey`  { @idx_fields =("`col_int_nokey`") ; @idx_select_fields=("table1 . `col_int_nokey` AS idx_field1") ; "" } |
  `pk`, `col_int_key`  { @idx_fields =("`pk`", "`col_int_key`") ; @idx_select_fields=("table1 . `pk` AS idx_field1" , "table1 . `col_int_key` AS idx_field2") ;  "" } | 
  `col_int_key` , `pk` { @idx_fields =("`col_int_key`", "`pk`") ; @idx_select_fields=("table1 . `col_int_key` AS idx_field1" , "table1 . `pk` AS idx_field2") ;  "" } | 
  `pk` , `col_int_nokey` { @idx_fields =("`pk`", "`col_int_nokey`") ; @idx_select_fields=("table1 . `pk` AS idx_field1" , "table1 . `col_int_nokey` AS idx_field2") ;  "" } | 
  `col_int_nokey` , `pk` { @idx_fields =("`col_int_nokey`", "`pk`") ; @idx_select_fields=("table1 . `col_int_nokey` AS idx_field1" , "table1 . `pk` AS idx_field2") ;  "" } |
  `pk` , `col_int_key` , `col_int_nokey`  { @idx_fields =("`pk`", "`col_int_key`", "`col_int_nokey`") ; @idx_select_fields=("table1 . `pk` AS idx_field1" , "table1 . `col_int_key` AS idx_field2", "table1 . `col_int_nokey` AS idx_field3 " ) ; "" } | 
  `pk` , `col_int_nokey` , `col_int_key`  { @idx_fields =("`pk`", "`col_int_key`", "`col_int_nokey`") ; @idx_select_fields=("table1 . `pk` AS idx_field1" , "table1 . `col_int_key` AS idx_field2", "table1 . `col_int_nokey` AS idx_field3 " ) ; "" } |
  `col_int_key` , `pk` , `col_int_nokey`  { @idx_fields =("`pk`", "`col_int_key`", "`col_int_nokey`") ; @idx_select_fields=("table1 . `pk` AS idx_field1" , "table1 . `col_int_key` AS idx_field2", "table1 . `col_int_nokey` AS idx_field3 " ) ; "" } |
  `col_int_key` , `col_int_nokey` , `pk`  { @idx_fields =("`pk`", "`col_int_key`", "`col_int_nokey`") ; @idx_select_fields=("table1 . `pk` AS idx_field1" , "table1 . `col_int_key` AS idx_field2", "table1 . `col_int_nokey` AS idx_field3 " ) ; "" } |
  `col_int_nokey` , `col_int_key` , `pk`  { @idx_fields =("`pk`", "`col_int_key`", "`col_int_nokey`") ; @idx_select_fields=("table1 . `pk` AS idx_field1" , "table1 . `col_int_key` AS idx_field2", "table1 . `col_int_nokey` AS idx_field3 " ) ;  "" } |
  `col_int_nokey` , `pk` , `col_int_key`  { @idx_fields =("`pk`", "`col_int_key`", "`col_int_nokey`") ; @idx_select_fields=("table1 . `pk` AS idx_field1" , "table1 . `col_int_key` AS idx_field2", "table1 . `col_int_nokey` AS idx_field3 " ) ; "" } ;

################################################################################
# int-specific query rules
################################################################################

tame_int_select:
  SELECT idx_field_list FROM join_clause WHERE int_idx_where_list opt_where_list order_by_clause ;

int_idx_where_list:
   int_idx_where_item | int_idx_where_list and_or int_idx_where_item ;

int_idx_where_item:
   { "table1 . ".$prng->arrayElement(\@idx_fields) } comparison_operator int_value |
   { "table1 . ".$prng->arrayElement(\@idx_fields) } comparison_operator existing_table_item . int_indexed | 
   { "table1 . ".$prng->arrayElement(\@idx_fields) } not BETWEEN _tinyint_unsigned[invariant] AND (_tinyint_unsigned[invariant] + int_value ) |
   { "table1 . ".$prng->arrayElement(\@idx_fields) } not IN (number_list) |
   { "table1 . ".$prng->arrayElement(\@idx_fields) } not BETWEEN _digit[invariant] AND (_digit[invariant] + int_value ) |
   { "table1 . ".$prng->arrayElement(\@idx_fields) } IS not NULL ;
   


################################################################################
# general-purpose rules
################################################################################

wild_query:
  SELECT select_list FROM join_clause WHERE where_list order_by_clause ; 

select_list:
  select_item | select_item | select_item , select_list ;

select_item:
  table_one_two . _field AS { my $f = "field".++$fields ; $f } ; 

join_clause:
  	( { $idx_tables[0].' AS  table'.++$tables } join_type new_table_item ON (join_condition_list ) ) |
        ( { $idx_tables[0].' AS  table'.++$tables } join_type ( ( new_table_item join_type new_table_item ON (join_condition_list ) ) ) ON (join_condition_list ) ) ;

join_condition_list:
  join_condition_item | join_condition_item | join_condition_item | 
  ( join_condition_item ) and_or (join_condition_item ) ;

join_condition_item:
  current_table_item . int_indexed = previous_table_item . int_indexed |
  current_table_item . char_indexed = previous_table_item . char_indexed |
  current_table_item . int_indexed join_condition_operator previous_table_item . int_indexed |
  current_table_item . char_indexed join_condition_operator previous_table_item . char_indexed ;

join_type:
	INNER JOIN | left_right outer JOIN | STRAIGHT_JOIN ; 

left_right:
	LEFT | LEFT | LEFT | RIGHT ;

outer:
	| | | | OUTER ;

index_type:
  BTREE | HASH ;

index_table:
  { my $idx_table = $prng->arrayElement($executors->[0]->tables()) ; push @idx_tables, $idx_table ; $idx_table } ;

idx_field_list:
  { scalar(@idx_fields) > 0 ? join(', ' , @idx_select_fields) : "" }  , select_list  ;

opt_where_list:
  | | | | | and_or where_list ;

where_list:
  where_item | where_item | where_item | ( where_list and_or where_item ) ;

where_item:
  existing_table_item . int_field_name comparison_operator _digit |
  existing_table_item . int_field_name comparison_operator existing_table_item . int_field_name |
  existing_table_item . char_field_name comparison_operator _char |
  existing_table_item . char_field_name comparison_operator existing_table_item . char_field_name |
  existing_table_item . _field IS not NULL |
  existing_table_item . `pk` IS not NULL ;

order_by_clause:
	| | |
        ORDER BY total_order_by desc limit |
	ORDER BY order_by_list  ;

total_order_by:
	{ join(', ', map { "field".$_ } (1..$fields) ) };

order_by_list:
	order_by_item  |
	order_by_item  , order_by_list ;

order_by_item:
	existing_select_item desc ;

desc:
        ASC | | | | DESC ; 

limit:
	| | LIMIT limit_size | LIMIT limit_size OFFSET int_value;

limit_size:
    1 | 2 | 10 | 100 | 1000;

################################################################################
# utility / helper rules
################################################################################

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

################################################################################
# miscellaneous rules for query elements
################################################################################

comparison_operator:
	= | > | < | != | <> | <= | >= ;

int_value:
     _digit | _digit | _digit | _digit | _digit | digit | other_int ;

other_int:
    _tinyint_unsigned | 20 | 25 | 30 | 35 | 50 | 65 | 75 | 100 ;

int_indexed:
    `pk` | `col_int_key` ;

int_field_name: 
    int_indexed | `col_int_nokey` ;

char_indexed:  
    `col_varchar_key` ;

char_field_name:
    char_indexed | `col_varchar_nokey` ; 

number_list:
        int_value | number_list, int_value ;

char_list: 
        _char | char_list, _char ;

table_one_two:
   table1 | table2 | table2 | table2 ;

################################################################################
# We are trying to skew the ON condition for JOINs to be largely based on      #
# equalities, but to still allow other arithmetic operators                    #
################################################################################
join_condition_operator:
    comparison_operator | = | = | = ;

and_or:
   AND | AND | AND | AND | OR ;

not:
   | | | | NOT ;

