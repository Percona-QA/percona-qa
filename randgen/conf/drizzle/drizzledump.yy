# drizzledump.yy
# grammar for generating test beds for drizzledump
# one or more tables are selected, populated, then altered
# the drizzledump validator will handle dumping, restoration
# and validation of the tables restored from the dump

query:
  { $tables = 0 ;  "" } 
  DROP DATABASE IF EXISTS drizzledump_db ; DROP DATABASE IF EXISTS drizzledump_db_restore ; CREATE DATABASE drizzledump_db ; CREATE DATABASE drizzledump_db_restore ; USE drizzledump_db ; create_test_table_list ; SELECT 1 ;

create_test_table_list:
# rule for picking one or more tables from the initial test bed
# sub-rules handle table population and composition
# this line of the rule is disabled currently (want only one table at a time:  create_test_table_list ; create_test_table_set | 
  create_test_table_set | create_test_table_set ;

create_test_table_set:
  create_table ; populate_table ; modify_table ;

create_table:
# even though all test tables have the same columns, they are created in
# different orders, so we randomly choose a table from the test db
# to enhance randomness / alter the composition of our test tables
  CREATE TABLE new_test_table LIKE `test` . _table ;

populate_table:
# We fill the test table with rows SELECT'ed from the
# existing tables in the test db
  insert_query_list ;

insert_query_list:
  insert_query_list ; insert_query | insert_query | insert_query ;

insert_query:
# We work on one test table at a time, thus we use the $tables variable to let us
# reference the current table (started in the create_table rule) here
  INSERT INTO {"dump_table".$tables } ( insert_column_list ) SELECT insert_column_list FROM `test` . _table insert_where_clause;

insert_where_clause:
# we use a WHERE clause on the populating SELECT to increase randomness
  | ;

insert_column_list:
# We use a set column list because even though all tables have the same
# columns, each table has a different order of those columns for 
# enhanced randomness
 `col_char_10` , `col_char_10_key` , `col_char_10_not_null` , `col_char_10_not_null_key` ,
 `col_char_1024` , `col_char_1024_key` , `col_char_1024_not_null` , `col_char_1024_not_null_key` ,
 `col_int` , `col_int_key` , `col_int_not_null` , `col_int_not_null_key` ,
 `col_bigint` , `col_bigint_key` , `col_bigint_not_null` , `col_bigint_not_null_key` ,
 `col_enum` , `col_enum_key` , `col_enum_not_null` , `col_enum_not_null_key` ,
 `col_text` , `col_text_key` , `col_text_not_null` , `col_text_not_null_key` 
 ;


modify_table:
# We alter the tables by ALTERing the table and DROPping COLUMNS
# we also include not dropping any columns as an option
# TODO:  Allow for adding columns
 | ;

new_test_table:
# This rule should generate tables to be dumped named dump_table1, dump_table2, etc
  { "dump_table".++$tables } ;


  
 
