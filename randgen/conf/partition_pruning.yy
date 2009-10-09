query:
  { @nonaggregates = () ; $tables = 0 ; $fields = 0 ; "" } query_type ;


query_type:
  select | select | select | select | select |
  select | select | select | select | select |
  select | select | select | select | select |
  update | update | update | delete | delete ;

distict:  DISTINCT | | | | | | | | | ;

select_option: SQL_SMALL_RESULT | | | | | | | | | | | | | | | | | | | | ;

explain_extended:
    | | | | | | | | | explain_extended2 ;

explain_extended2: | | | | EXPLAIN | EXPLAIN EXTENDED ;


select:
  simple_select | mixed_select ;

simple_select:
  explain_extended SELECT simple_select_list
  FROM join_list
  WHERE where_list 
  optional_group_by
  having_clause
  order_by_clause ;


mixed_select:
  explain_extended SELECT select_list
  FROM join_list
  WHERE where_list
  group_by_clause
  having_clause
  order_by_clause ;

update:
  int_update | char_update ;

int_update:
 int_update_query ; int_select_count ;

int_update_query:
  UPDATE _table[invariant] SET `int_signed` = _digit[invariant] WHERE special_where_list ; 

int_select_count:
  SELECT COUNT(*) FROM _table[invariant] WHERE `int_signed` = _digit[invariant];

char_update:
  char_update_query ; char_select_count ;

char_update_query:
  UPDATE _table[invariant] SET `varchar_5_utf8` = _char[invariant] WHERE special_where_list;

char_select_count:
  SELECT COUNT(*) FROM _table[invariant] WHERE `varchar_5_utf8` = _char[invariant];


delete:
  int_delete ;

int_delete:
  int_delete_query ; int_select_count ;

int_delete_query:
  DELETE FROM _table[invariant] WHERE `int_signed` = _digit[invariant] and_or special_where_list ;

special_where_list:
  ( special_where_item ) | ( special_where_item ) |
  ( special_where_list and_or special_where_item ) ;

special_where_item:
  _table[invariant] . partitioned_int_field arithmetic_operator _digit |
  _table[invariant] . partitioned_int_field not BETWEEN _digit[invariant] AND ( _digit[invariant] + _digit ) |
  _table[invariant] . partitioned_int_field not IN ( number_list ) |
  _table[invariant] . partitioned_char_field arithmetic_operator _char |
  _table[invariant] . partitioned_char_field not IN (char_list ) ;

#######################################################
# query clause rules
#######################################################

select_list:
   new_select_item | new_select_item | new_select_item |
   new_select_item, select_list | new_select_item, select_list ;

simple_select_list:
   nonaggregate_select_item | nonaggregate_select_item | nonaggregate_select_item |
   nonaggregate_select_item | nonaggregate_select_item, simple_select_list | nonaggregate_select_item, simple_select_list ;

join_list:
   new_table_item join_type new_table_item ON ( join_condition ) |
   new_table_item | new_table_item | new_table_item | new_table_item ;

join_type:
   INNER JOIN | left_right outer JOIN | STRAIGHT_JOIN ;

join_condition:
   current_table_item . int_indexed = previous_table_item . int_indexed |
   current_table_item . char_indexed = previous_table_item . char_indexed ; 


#########################################################
# We use partition pruning friendly clauses here
#########################################################

where_list:
  ( where_item ) | ( where_item ) |
  ( where_list and_or where_item ) ;

where_item:
  table1 . partitioned_int_field arithmetic_operator existing_table_item . int_field |
  table1 . partitioned_int_field arithmetic_operator _digit |
  table1 . partitioned_int_field not BETWEEN _digit[invariant] AND ( _digit[invariant] + _digit ) |
  table1 . partitioned_int_field not IN ( number_list ) |
  table1 . partitioned_char_field arithmetic_operator _char |
  table1 . partitioned_char_field not IN (char_list ) | 
  table1 . utf8_char_field arithmetic_operator existing_table_item . utf8_char_field |
  table1 . latin1_char_field arithmetic_operator existing_table_item . latin1_char_field |
  table1 . cp932_char_field arithmetic_operator existing_table_item . cp932_char_field ; 
  

partitioned_int_field:
    `int_signed` ;

partitioned_char_field:
    `varchar_5_utf8` | `varchar_5_cp932` | `varchar_5_latin1` |
    `varchar_10_utf8` | `varchar_10_cp932` | `varchar_10_latin1` ;

int_field:
    `int_signed` | `int_signed_key` ;

utf8_char_field:
  `varchar_5_utf8` | `varchar_5_utf8_key` | `varchar_10_utf8` | `varchar_10_utf8_key` ;

latin1_char_field:
  `varchar_5_latin1` | `varchar_5_latin1_key` | `varchar_10_latin1` | `varchar_10_latin1_key`;

cp932_char_field:
  `varchar_5_cp932` | `varchar_5_cp932_key` | `varchar_10_cp932` | `varchar_10_cp932_key` ; 

char_field:
  utf8_char_field | latin1_char_field | cp932_char_field ;

date_field:
  `datetime` | `date_key` | `datetime_key` | `date` ; 

non_int_field:
  char_field | date_field ;

number_list:
        _digit | number_list, _digit ;

char_list: 
        _char | char_list, _char ;

#########################################################
# GROUP BY / HAVING / ORDER BY rules
#########################################################
group_by_clause:
        { scalar(@nonaggregates) > 0 ? " GROUP BY ".join (', ' , @nonaggregates ) : "" }  ;

optional_group_by:
        | | | | | | | | | group_by_clause ;

having_clause:
        | | | | | | | | | HAVING having_list;

having_list:
        having_item |
        having_item |
        (having_list and_or having_item)  ;

having_item:
        existing_select_item arithmetic_operator value |
        existing_select_item arithmetic_operator value |
        existing_select_item arithmetic_operator value |
        existing_select_item arithmetic_operator value |
        existing_select_item arithmetic_operator existing_select_item ;

order_by_clause:
 | | | | ORDER BY total_order_by desc limit ;

total_order_by:
        { join(', ', map { "field".$_ } (1..$fields) ) };

desc:
  ASC | | | | DESC ;

limit:
  | | | | | | | | | | LIMIT limit_size | LIMIT limit_size OFFSET _digit;

limit_size:
    1 | 2 | 10 | 100 | 1000;

#########################################################
# query component rules
#########################################################

new_select_item:
  nonaggregate_select_item  | aggregate_select_item ;

nonaggregate_select_item:
  table_one_two . _field AS { my $f = "field".++$fields ; push @nonaggregates , $f ; $f } ;

aggregate_select_item:
  aggregate table_one_two . non_int_field ) AS { "field".++$fields } |
  int_aggregate table_one_two . int_field ) AS { "field".++$fields } ;


new_table_item:
	_table AS { "table".++$tables };

table_one_two:
      table1 | table1 | table1 | table1 | table2 ;

current_table_item:
	{ "table".$tables };

previous_table_item:
	{ "table".($tables - 1) };

existing_table_item:
	{ "table".$prng->int(1,$tables) };

left_right:
        LEFT | RIGHT ;

outer: 
        | | | OUTER ;

existing_select_item:
	{ "field".$prng->int(1,$fields) };

int_indexed:
    `int_signed_key` ;

char_indexed:
    `varchar_5_key` | `varchar_10_key` ;

arithmetic_operator:
	= | > | < | != | <> | <= | >= ;

aggregate:
        COUNT( | MIN( | MAX( ;

int_aggregate:
        SUM( | aggregate ;

and_or:
        AND | AND | OR ;

not:
   | | | | NOT ;


value:
        _digit | _digit | _digit | _digit | _digit |
        _char | _char | _char | _char | _char ;
