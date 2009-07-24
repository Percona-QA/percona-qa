# WL#5004 Comprehensive Locking Stress Test for Azalea
#
# Grammar for testing DML, DDL, FLUSH, LOCK/UNLOCK, transactions
#
# Created:
#    2009-07 Matthias Leich 
#
# This is a prototype which means it might be incomplete and contain errors.
#
# General architecture rules by thumb and experiences:
# 1. Work on copies of the objects created by gendata.pl
# 2. Do not modify the objects created by by gendata.pl
# Hereby we prevent that we run out of tables or rows etc.
# 3. Use small name spaces for objects (tables etc.) so that we have a significant likelihood
#    that a statement hits an existing object.
# 4. Distinct between two kinds of object name spaces and treat the corresponding objects different.
#    This is experimental and might be removed in case it does not fulfill the expectations.
#    "long life" ("ll")
#    - sequence: CREATE object, maybe fill in content, wait some time, DROP object
#    - No other DDL on this object
#    This should ensure that a thread has a chance to run several DML statements on this object
#    before it gets dropped.
#    "short life" ("sl")
#    - no sequence
#    - there are single DDL statements which CREATE, ALTER, DROP etc. this object
#    This should ensure that a thread running a transaction has a chance to meet DDL for this
#    object sent from another session.
# 5. Any statement sequence has to be in one line.
# 6. Be carefull when having a ';' before a '|'.
# 7. There must be no "superfluous" spaces between the beginning of the line and
#    the first significant character which of course might be a space.
#    Typical bad effect: Empty filed or table names, statements consisting of '"' etc.
# 8. Strange effect like above? '|' instead of ';' between statements of a sequence?
# 9. Names of variables must be surrounded by spaces. Otherwise the name of the variable
#    and not it's value will be used. -> Problem with SHOW ... LIKE 'table_name'.
# 10. There must be no space between grammar element name and the ':'.
#     Example: "a:" but never "a :".
# 11. There is some auxiliary SQL where I did not found a simple pure PERL based solution
#     a) SET @aux = SLEEP(...)                Wait some time
#        Wait some time
#     b) SET @aux = 'Fill variable <dollar>table_name1 { $table_name1 = $basetablenamesl } ' ;
#        Fill the content of $basetablenamesl into $table_name1
#     SET @var ... is better then SELECT ... because RQG seems to run for every SELECT ...
#     an additional EXPLAIN SELECT ....
#     Surrounding text like "FILL VARIABLE ..." should support debugging.
# 12. Use uppercase characters for strings in statements. This avoids any not intended treatment
#     as grammar item.
#
# Naming convention:
# ------------------
# t1_0* base table (no merge)
# t1_1* temporary base table
# t1_2* merge table
# t1_3* view
# *_*0  "long life" objects
# *_*1  "short life" objects

# Done:
# RENAME, DROP, TRUNCATE, SELECT, select SUBQUERY, select JOIN, select UNION
#
# Missing: LOAD/UNLOAD, DO, HANDLER ....
#
rand_life_time:
	# { $rand_life_time = $prng->int(0,10)	}	;
	0.1	;

table_name:
	# Get a random name from the "table" namespace.
	# "table" name space = UNION of "base table", "temporary base table", "view", "merge table" name spaces
	# "table" name space = UNION of "base table long life", "base table short life" name spaces
	{ $tablename       = "t1_" . $prng->int(0,3) . $prng->int(0,9) . $prng->int(0,1) } ;
#
table_name_ll:
	# Get a random name from the "table long life" namespace.
	{ $tablenamell     = "t1_" . $prng->int(0,3) . $prng->int(0,9) . "0"             } ;
#
table_name_sl:
	# Get a random name from the "table short life" namespace.
	{ $tablenamesl     = "t1_" . $prng->int(0,3) . $prng->int(0,9) . "1"             } ;


########## The base table name space ####################
base_table_name:
	# Get a random name from the "base table" name space.
	# "base table" name space = UNION of "base table long life" and "base table short life" name spaces
	{ $basetablename   = "t1_" . "0"             . $prng->int(0,9) . $prng->int(0,1) } ;
#
base_table_name_ll:
	# Get a random name from the "base table long life" name space.
	{ $basetablenamell = "t1_" . "0"             . $prng->int(0,9) . "0"             } ;
#
base_table_name_sl:
	# Get a random name from the "base table short life" name space.
	{ $basetablenamesl = "t1_" . "0"             . $prng->int(0,9) . "1"             } ;
#
base_table_list:
	base_table_name | base_table_name, base_table_name	;
base_table_list_ll:
	base_table_name_ll | base_table_name_ll, base_table_name_ll	;
base_table_list_sl:
	base_table_name_sl | base_table_name_sl, base_table_name_sl	;

########## The temp table name space ####################
temp_table_name:
	# Get a random name from the "temp table" name space.
	# "temp table" name space = UNION of "temp table long life" and "temp table short life" name spaces
	{ $temptablename   = "t1_" . "1"             . $prng->int(0,9) . $prng->int(0,1) } ;
#
temp_table_name_ll:
	# Get a random name from the "temp table long life" name space.
	{ $temptablenamell = "t1_" . "1"             . $prng->int(0,9) . "0"             } ;
#
temp_table_name_sl:
	# Get a random name from the "temp table short life" name space.
	{ $temptablenamesl = "t1_" . "1"             . $prng->int(0,9) . "1"             } ;
#
temp_table_list:
	temp_table_name | temp_table_name, temp_table_name	;
temp_table_list_ll:
	temp_table_name_ll | temp_table_name_ll, temp_table_name_ll	;
temp_table_list_sl:
	temp_table_name_sl | temp_table_name_sl, temp_table_name_sl	;

########## The merge table name space ####################
merge_table_name:
	# Get a random name from the "merge table" name space.
	# "merge table" name space = UNION of "merge table long life" and "merge table short life" name spaces
	{ $mergetablename   = "t1_" . "2"             . $prng->int(0,9) . $prng->int(0,1) } ;
#
merge_table_name_ll:
	# Get a random name from the "merge table long life" name space.
	{ $mergetablenamell = "t1_" . "2"             . $prng->int(0,9) . "0"             } ;
#
merge_table_name_sl:
	# Get a random name from the "merge table short life" name space.
	{ $mergetablenamesl = "t1_" . "2"             . $prng->int(0,9) . "1"             } ;
#
merge_table_list:
	merge_table_name | merge_table_name, merge_table_name	;
merge_table_list_ll:
	merge_table_name_ll | merge_table_name_ll, merge_table_name_ll	;
merge_table_list_sl:
	merge_table_name_sl | merge_table_name_sl, merge_table_name_sl	;


#
base_temp_table_name:
	{ $base_temp_table_name = "t1_" . $prng->int(0,1) . $prng->int(0,9) . $prng->int(0,1) } ;
#
base_temp_table_name_ll:
	{ $temptablenamesl      = "t1_" . $prng->int(0,1) . $prng->int(0,9) . "0"             } ;
#
base_temp_table_name_sl:
	{ $temptablenamesl      = "t1_" . $prng->int(0,1) . $prng->int(0,9) . "1"             } ;
#
base_temp_table_list:
	base_temp_table_name | base_temp_table_name, base_temp_table_name	;
#
base_temp_table_list_ll:
	base_temp_table_name_ll | base_temp_table_name_ll, base_temp_table_name_ll	;
#
base_temp_table_list_sl:
	base_temp_table_name_sl | base_temp_table_name_sl, base_temp_table_name_sl	;
#

view_name:
	# Get a random name from the "view table" name space.
	# "view table" name space = UNION of "view table long life" and "view table short life" name spaces
	{ $viewname        = "t1_" . "3"             . $prng->int(0,9) . $prng->int(0,1) } ;
#
view_name_ll:
	# Get a random name from the "view table long life" name space.
	{ $viewnamell      = "t1_" . "3"             . $prng->int(0,9) . "0"             } ;
#
view_name_sl:
	# Get a random name from the "view table short life" name space.
	{ $viewnamesl      = "t1_" . "3"             . $prng->int(0,9) . "1"             } ;

template_table_name:
	# Get the name of one of the template tables
	{ $templatetablename = $prng->arrayElement($executors->[0]->tables()) } ;

procedure_name:
	# Get a random name from the "procedure" namespace.
	# "procedure" name space = UNION of "procedure long life", "procedure short life" name spaces
	{ $procedurename      = "p1_" . $prng->int(0,9) . $prng->int(0,1) } ;

procedure_name_ll:
	# Get a random name from the "procedure long life" namespace.
	{ $procedurenamell    = "p1_" . $prng->int(0,9) . "0"             } ;

procedure_name_sl:
	# Get a random name from the "procedure short life" namespace.
	{ $procedurenamesl    = "p1_" . $prng->int(0,9) . "1"             } ;

function_name:
	# Get a random name from the "function" namespace.
	# "function" name space = UNION of "function long life", "function short life" name spaces
	{ $functionname      = "f1_" . $prng->int(0,9) . $prng->int(0,1) } ;

function_name_ll:
	# Get a random name from the "function long life" namespace.
	{ $functionnamell    = "f1_" . $prng->int(0,9) . "0"             } ;

function_name_sl:
	# Get a random name from the "function short life" namespace.
	{ $functionnamesl    = "f1_" . $prng->int(0,9) . "1"             } ;

trigger_name:
	# Get a random name from the "trigger" namespace.
	# "trigger" name space = UNION of "trigger long life", "trigger short life" name spaces
	{ $triggername      = "tr1_" . $prng->int(0,9) . $prng->int(0,1) } ;

trigger_name_ll:
	# Get a random name from the "trigger long life" namespace.
	{ $triggernamell    = "tr1_" . $prng->int(0,9) . "0"             } ;

trigger_name_sl:
	# Get a random name from the "trigger short life" namespace.
	{ $triggernamesl    = "tr1_" . $prng->int(0,9) . "1"             } ;

query:
	ddl | dml | transaction | show ;
	# ddl | dml | lock | transaction ;
	# ddl | dml | lock | transaction | flush;
	# FLUSH TABLES WITH/(without) READ LOCK removed because of Bug#45066

transaction:
	START TRANSACTION | COMMIT | ROLLBACK | SAVEPOINT A | ROLLBACK TO SAVEPOINT A ;

ddl:
	TRUNCATE TABLE base_table_name_sl			|
	create_base_temp_table							|
	drop_base_temp_table								|
	alter_base_temp_table							|
	rename_base_temp_table							|
	base_table_sequence								|
	create_merge_table								|
	drop_merge_table									|
	alter_merge_table									|
	merge_table_sequence								|
	create_view											|
	drop_view											|
	alter_view											|
	rename_view											|
	view_sequence										|
	create_procedure									|
	drop_procedure										|
	alter_procedure									|
	procedure_sequence								|
	create_function									|
	drop_function										|
	alter_function										|
	function_sequence									|
	create_trigger										|
	drop_trigger										|
	trigger_sequence									|
	analyze_table										|
	optimize_table										|
	checksum_table										|
	check_table											|
	repair_table										;

show:
	show_tables						|
	show_create_table				|
	show_table_status				|
	show_columns					|
	show_create_view				|
	show_create_function			|
	show_function_code			|
	show_function_status			|
	show_create_procedure		|
	show_procedure_code			|
	show_procedure_status		|
	show_triggers					|
	show_create_trigger			;

show_tables:
	SHOW TABLES show_tables_part ;
#
show_tables_part:
	# FIXME: Add "WHERE"
	 | like_table_name	;
#
like_table_name:
	# all tables, base table name space | temp table name space | .....
	# Attention: LIKE 'table_name' does not work.
	LIKE 't1_0%' | LIKE 't1_1%' | LIKE 't1_2%' | LIKE 't1_3%'	;
#
show_create_table:
	# Works also for views
	SHOW CREATE TABLE table_name	;
#
#
show_table_status:
	# Works also for views
	# FIXME: Add "WHERE"
	SHOW TABLE STATUS show_table_status_part	;
#
show_table_status_part:
	# FIXME: Add "WHERE"
	 | like_table_name   ;
#
show_columns:
	SHOW full COLUMNS from_in table_name show_columns_part ;
#
full:
	 | | FULL	;
#
from_in:
	FROM | IN	;
show_columns_part:
	# Attention: LIKE '_field' does not work, because RQG does not expand _field.
	#            LIKE '%int%' does not work, because RQG expands it to something like LIKE '%822214656%'.
	# FIXME: Add "WHERE"
	 | LIKE '%INT%'	;
#
#
show_create_view:
	SHOW CREATE VIEW view_name  ;
#
#
show_create_function:
	SHOW CREATE FUNCTION function_name	;
show_function_code:
	SHOW FUNCTION CODE function_name	;
show_function_status:
	SHOW FUNCTION STATUS show_function_status_part	;
show_function_status_part:
	# FIXME: Add "WHERE"
	 | LIKE 'f1_%'	;
#
#
show_create_procedure:
	SHOW CREATE PROCEDURE procedure_name	;
show_procedure_code:
	SHOW PROCEDURE CODE procedure_name	;
show_procedure_status:
	SHOW PROCEDURE STATUS show_procedure_status_part	;
show_procedure_status_part:
	# FIXME: Add "WHERE"
	 | LIKE 'p1_%'	;
#
#
#
show_triggers:
	SHOW TRIGGERS show_triggers_part	;
show_triggers_part:
	# FIXME: Add "WHERE"
	 | LIKE 'tr1_%';

show_create_trigger:
	SHOW CREATE TRIGGER trigger_name	;


########## Base an temporary tables ####################
create_base_temp_table:
	CREATE           TABLE base_table_name_sl create_table_part	|
	CREATE TEMPORARY TABLE temp_table_name_sl create_table_part	;
#
create_table_part:
	LIKE template_table_name	|
	AS used_select					;
#
#
drop_base_temp_table:
	DROP           TABLE base_table_list_ll	|
	DROP TEMPORARY TABLE temp_table_list_sl	;
#
#
alter_base_temp_table:
	ALTER ignore TABLE base_temp_table_name_sl alter_base_temp_table_part	;
	# "online" removed because of Bug#45143
#
alter_base_temp_table_part:
	ENGINE = engine				|
	COMMENT = 'UPDATED NOW()'	;
#
#
analyze_table:
	ANALYZE not_to_binlog_local TABLE base_table_list	;
#
not_to_binlog_local:
	 | NO_WRITE_TO_BINLOG | LOCAL	;
#
optimize_table:
	# VIEW : Statement not disallowed but server response is
	#    Table	Op	Msg_type	Msg_text
	#    test.v1	optimize	Error	Table 'test.v1' doesn't exist
	#    test.v1	optimize	status	Operation failed
	# MERGE TABLE : Statement allowed, but no efffect.
	#    Table  Op      Msg_type        Msg_text
	#    +test.t1m       optimize        note    The storage engine for the table doesn't support optimize
	# -> We run this for all table types.
	OPTIMIZE not_to_binlog_local TABLE base_table_list ;
#
checksum_table:
	CHECKSUM TABLE base_table_list quick_extended	;
#
quick_extended:
	 | QUICK | EXTENDED	;
#
extended:
	 | | | | | | | | | EXTENDED ;
	# Only 10 %
#
check_table:
	CHECK TABLE base_table_list check_table_options	;
#
check_table_options:
	 | FOR UPGRADE | QUICK | FAST | MEDIUM | EXTENDED | CHANGED ;
#
#
repair_table:
	REPAIR not_to_binlog_local TABLE base_table_list quick extended use_frm	;
#
rename_base_temp_table:
	# RENAME TABLE works also on VIEWs but we do not generate it here.
	# FIXME: Reduce the redundancy if possible.
	RENAME TABLE base_table_name_sl TO base_table_name_sl |
	RENAME TABLE base_table_name_sl TO base_table_name_sl, base_table_name_sl TO base_table_name_sl |
	RENAME TABLE base_table_name_sl TO base_table_name_sl |
	RENAME TABLE base_table_name_sl TO base_table_name_sl, temp_table_name_sl TO temp_table_name_sl ;
#
#
base_table_sequence:
	CREATE TABLE base_table_name_ll LIKE template_table_name ; INSERT INTO $basetablenamell SELECT * FROM $templatetablename ; COMMIT ; SET @aux = SLEEP( rand_life_time ) ; DROP TABLE $basetablenamell |
	CREATE TABLE base_table_name_ll AS used_select ;                                                                                    SET @aux = SLEEP( rand_life_time ) ; DROP TABLE $basetablenamell	;
#

########## Merge table ####################
create_merge_table:
	# There is a high risk that the tables which we pick for merging do not fit together because they
	# have different structures. We try to reduce this risk to end up with no merge table at all
	# by the following:
	# 1. Let the merge table have the structure of the first base table.
	#    CREATE TABLE <merge table> LIKE <first base table>
	# 2. Let the merge table be based on the first base table.
	#    ALTER TABLE <merge table> ENGINE = MERGE UNION(<first base table>)
	# 3. Add the second base table to the merge table.
	#    ALTER TABLE <merge table> UNION(<first base table>, <second merge table>) 
	pick_table_name1 ; pick_table_name2 ; CREATE TABLE merge_table_name_sl LIKE $table_name1 ; convert_to_merge_table	;
pick_table_name1:
	# Fill $table_name1
	SET @aux = 'MERGE TABLE WILL USE base_table_name_sl FOR THE BASE'; SET @aux = 'FILL VARIABLE <dollar>table_name1 { $table_name1 = $basetablenamesl } ' ;
pick_table_name2:
	# Fill $table_name2
	SET @aux = 'MERGE TABLE WILL USE base_table_name_sl FOR THE BASE'; SET @aux = 'FILL VARIABLE <dollar>table_name2 { $table_name2 = $basetablenamesl } ' ;
convert_to_merge_table:
	ALTER TABLE $mergetablenamesl ENGINE = MERGE UNION ( $table_name1 ) ; ALTER TABLE $mergetablenamesl ENGINE = MERGE UNION ( $table_name1 , $table_name2 ) insert_method	;
insert_method:
	 | INSERT_METHOD = insert_method_value | INSERT_METHOD = insert_method_value | | INSERT_METHOD = insert_method_value	;
insert_method_value:
	NO | FIRST | LAST	;
drop_merge_table:
	DROP TABLE merge_table_name_sl ;
merge_table_sequence:
	# Notes:
	# There is a significant likelihood that a random picked table names as base for the merge table cannot
	# be used for the creation of a merge table because the corresponding tables
	# - must exist
	# - use the storage engine MyISAM
	# - have the same layout.
	# Therefore we create here all we need.
	# But the use of "base_table_name_sl" for the tables to be merged guarantees that these tables
	# are under full DDL/DML load.
	# I do not DROP the underlying tables at sequence end because I hope that "drop_base_temp_table" will do this sooner or later.
	pick_template_name ; create_table1_for_merging ; create_table2_for_merging ; create_merge_table_ll ; 
create_table1_for_merging:
	pick_table_name1 ; CREATE TABLE $table_name1 LIKE $templatetablename ; ALTER TABLE $table_name1 ENGINE = MyISAM ; INSERT INTO $table_name1 SELECT * FROM $templatetablename ;
create_table2_for_merging:
	pick_table_name2 ; CREATE TABLE $table_name2 LIKE $templatetablename ; ALTER TABLE $table_name2 ENGINE = MyISAM ; INSERT INTO $table_name2 SELECT * FROM $templatetablename ;
create_merge_table_ll:
	CREATE TABLE merge_table_name_ll LIKE $templatetablename ; ALTER TABLE $mergetablenamell ENGINE = MERGE UNION ( $table_name1 , $table_name2 )	insert_method	;
pick_template_name:
	# Fill $templatetablename
	SET @aux = 'WILL USE template_table_name AS TEMPLATE FOR MERGE TABLES' ;
#
#
alter_merge_table:
	# "online" removed because of Bug#45143
	# We do not chenage here the UNION because of the high risk that this fails.
	# And we have already ALTER ... UNION within convert_to_merge_table. There the base tables could be already under DML/DDL load.
	ALTER ignore TABLE merge_table_name_ll COMMENT = 'UPDATED NOW()'	;

########## Views ####################
create_view:
	CREATE ALGORITHM = view_algoritm VIEW view_name_sl AS used_select ;
#
view_algoritm:
	UNDEFINED | MERGE | TEMPTABLE ;
#
view_replace:
	 | | OR REPLACE ;
#
#
drop_view:
	DROP VIEW view_list restrict_cascade ;
#
view_list:
	view_name_sl | view_name_sl, view_name_sl ;
#
restrict_cascade:
	# RESTRICT and CASCADE, if given, are parsed and ignored.
	 | RESTRICT | CASCADE ;
#
#
alter_view:
	# Attention: Only changing the algorithm is not allowed.
	ALTER ALGORITHM = view_algoritm VIEW view_name_sl AS used_select ;
#
#
rename_view:
	# RENAME TABLE works also on VIEWs as long as the SCHEMA is not changed.
	# RENAME VIEW does not exist.
	RENAME TABLE view_name_sl TO view_name_sl											|
	RENAME TABLE view_name_sl TO view_name_sl, view_name_sl TO view_name_sl	;
#
#
view_sequence:
	CREATE ALGORITHM = view_algoritm VIEW view_name_ll AS used_select ; SET @aux = SLEEP( rand_life_time ) ; DROP VIEW $viewnamell	;


########## Stored procedure ####################
create_procedure:
	CREATE PROCEDURE procedure_name_sl  () BEGIN proc_stmt ; proc_stmt ; END ;
#
drop_procedure:
	DROP PROCEDURE IF EXISTS procedure_name_sl ;
#
proc_stmt:
	select | insert ;
#
alter_procedure:
	ALTER PROCEDURE procedure_name_sl COMMENT 'UPDATED NOW()';
#
procedure_sequence:
	CREATE PROCEDURE procedure_name_ll  () BEGIN proc_stmt ; proc_stmt ; END ; SET @aux = SLEEP( rand_life_time ) ; DROP PROCEDURE $procedurenamell ;

########## Function ####################
create_function:
	CREATE FUNCTION function_name_sl () RETURNS INTEGER BEGIN func_statement ; func_statement ; RETURN 1 ; END	;

func_statement:
	# All result sets of queries within a function must be processed within the function.
	# -> Use a CURSOR or SELECT ... INTO ....
	insert | delete | SELECT MAX(_field) FROM table_name INTO @aux	;

# RETURNS CHAR(50) DETERMINISTIC
	# -> RETURN CONCAT('Hello, ',s,'!')	;

drop_function:
	DROP FUNCTION function_name_sl	;
#
alter_function:
	ALTER FUNCTION function_name_sl COMMENT 'UPDATED NOW()'	;
#
function_sequence:
	CREATE FUNCTION function_name_ll () RETURNS INTEGER RETURN ( SELECT MOD(COUNT(DISTINCT _field),10) FROM base_table_name_sl )	; SET @aux = SLEEP( rand_life_time ) ; DROP PROCEDURE $functionnamell ;

########## Trigger ####################
create_trigger:
	CREATE TRIGGER trigger_name_sl trigger_time trigger_event ON base_table_name_sl FOR EACH ROW BEGIN trigger_action ; END ;
#
trigger_time:
	BEFORE | AFTER ;
#
trigger_event:
	INSERT | DELETE ;
#
trigger_action:
	insert | replace | delete | update | call procedure_name ;
#
#
drop_trigger:
	DROP TRIGGER trigger_name_sl	;
#
trigger_sequence:
	CREATE TRIGGER trigger_name_ll trigger_time trigger_event ON base_table_name_sl FOR EACH ROW BEGIN trigger_action ; END ; SET @aux = SLEEP( rand_life_time ) ; DROP TRIGGER $triggernamell ;


dml:
	PREPARE st1 FROM " dml2 " ; EXECUTE st1 ; DEALLOCATE PREPARE st1 |
	dml2 ;

dml2:
	select | insert | replace | delete | update | call procedure_name | show ;

select:
	# select = Just a query = A statement starting with "SELECT".
	select_part1 addition              into for_update_lock_in_share_mode ;

used_select:
	# used_select = The SELECT used in CREATE VIEW/TABLE ... AS <SELECT>, INSERT INTO ... SELECT
	# "PROCEDURE ANALYSE" and "INTO DUMPFILE/OUTFILE/@var" are not generated because they
	# are partially disallowed or cause garbage (PROCEDURE).
	select_part1 addition_no_procedure      for_update_lock_in_share_mode ;

select_part1:
	SELECT high_priority cache_results * FROM first_table_in_select AS A ;

high_priority:
	 | | | | HIGH_PRIORITY;
	# Only 20 %

cache_results:
	 | | | | SQL_CACHE | | | | | SQL_NO_CACHE ;
	# Only 20 %

first_table_in_select:
	# Attention: Derived tables are disallowed in views. Therefore they should be rare.
	table_name | table_name | table_name | table_name | table_name | (SELECT * FROM table_name) ;

addition:
	# Involve one (simple where condition) or two tables (subquery | join | union)
	where procedure | subquery procedure | join where procedure | procedure union where ;

addition_no_procedure:
	# Involve one (simple where condition) or two tables (subquery | join | union)
	# Don't add procedure.
	where           | subquery           | join where           |           union where ;

where:
	 | WHERE `pk` BETWEEN _digit AND _digit | WHERE function_name_sl() = _digit ;

union:
	UNION SELECT * FROM table_name AS B;

join:
	# Do not place a where condition here.
	NATURAL JOIN table_name B ;

subquery:
	correlated | non_correlated ;

subquery_part1:
	WHERE A.`pk` IN (SELECT `pk` FROM table_name AS B WHERE B.`pk` = ;

correlated:
	subquery_part1 A.`pk` ) ;
	# WHERE A.`pk` IN (SELECT `pk` FROM table_name AS B WHERE A.`pk` = B.`pk`);

non_correlated:
	subquery_part1 _digit ) ;
	# WHERE A.`pk` IN (SELECT `pk` FROM table_name AS B WHERE A.`pk` = _digit);

procedure:
	# procedure disabled because of Bug#46184 Crash, SELECT ... FROM derived table procedure analyze
	# | | | | | | | | | PROCEDURE ANALYSE(10, 2000);
	# Only 10 %
	;

	# Correct place of PROCEDURE ANALYSE(10, 2000)
	# 0. Attention: The result set of the SELECT gets replaced  by PROCEDURE ANALYSE output.
	# 1. WHERE ... PROCEDURE (no UNION of JOIN)
	# 2. SELECT ... PROCEDURE UNION SELECT ... (never after UNION)
	# 3. SELECT ... FROM ... PROCEDURE ... JOIN (never at statement end)
	# 4. Never in a SELECT which does not use a table
	# 5. Any INTO DUMPFILE/OUTFILE/@var must be after PROCEDURE ANALYSE.
	#    The content of DUMPFILE/OUTFILE/@var is from the PROCEDURE ANALYSE result set.
	# 6. CREATE TABLE ... AS SELECT PROCEDURE -> The table contains the PROCEDURE result set.
	# 7. INSERT ... SELECT ... PROCEDURE -> It's tried to INSERT the PROCEDURE result set.
	#    High likelihood of ER_WRONG_VALUE_COUNT_ON_ROW

into:
	 | | | | | | | | | | INTO into_object;
	# Only 10 %

into_object:
	# INSERT ... SELECT ... INTO DUMPFILE/OUTFILE/@var is not allowed
	# This also applies to CREATE TABLE ... AS SELECT ... INTO DUMPFILE/OUTFILE/@var
	# 1. @_letter is in average not enough variables compared to the column list.
	#    -> @_letter disabled till I find a solution.
	# 2. DUMPFILE requires a result set of one row
	#    Therefore 1172 Result consisted of more than one row is very likely.
	# OUTFILE _tmpnam | DUMPFILE _tmpnam | @_letter;
	OUTFILE _tmpnam ;

for_update_lock_in_share_mode:
	 | | | | | | | | | | | | | | | | | | FOR UPDATE | LOCK IN SHARE MODE ;

insert:
	# FIXME: Case with one assigned row is missing.
	INSERT low_priority_delayed_high_priority INTO table_name            used_select            on_duplicate_key_update ;
	# INSERT low_priority_delayed_high_priority INTO table_name ( _field ) used_select            on_duplicate_key_update |
	# INSERT low_priority_delayed_high_priority INTO table_name ( _field ) VALUES ( _digit ) on_duplicate_key_update ;

replace:
	# 1. No ON DUPLICATE .... option. In case of DUPLICATE key it runs DELETE old row INSERT new row.
	# 2. HIGH_PRIORITY is not allowed
	# FIXME: Case with one assigned row is missing.
	REPLACE low_priority_delayed INTO table_name used_select ;
	# REPLACE low_priority_delayed INTO table_name ( _field ) VALUES ( _digit ) ;

on_duplicate_key_update:
	 | | | | | | | | | ON DUPLICATE KEY UPDATE _field = _digit ;
	# Only 10 %

delete:
	# LIMIT row_count is disallowed in case we have multi table delete.
	# Example: DELETE low_priority quick ignore A , B FROM table_name AS A join where LIMIT _digit |
	# DELETE is ugly because a table alias is not allowed.
	DELETE low_priority quick ignore       FROM table_name      WHERE   `pk` > _digit LIMIT _digit |
	DELETE low_priority quick ignore A , B FROM table_name AS A join where |
	DELETE low_priority quick ignore A     FROM table_name AS A where_subquery ;

where_subquery:
	where           | subquery           ;

update:
	UPDATE low_priority ignore table_name SET _field = _digit WHERE `pk` > _digit LIMIT _digit |
	UPDATE low_priority ignore table_name AS A join SET A._field = _digit, B._field = _digit;

quick:
	 | | | | | | | | | QUICK ;
	# Only 10 %

engine:
	MEMORY | MyISAM | InnoDB ;

online:
	ONLINE | ;

lock:
	LOCK TABLE lock_list |
	UNLOCK TABLES ;

flush:
	FLUSH TABLES WITH READ LOCK |
	FLUSH TABLE table_name , table_name ;

lock_list:
	lock_item |
	lock_item , lock_item ;

lock_item:
	table_name lock_type ;

lock_type:
	READ local |
	low_priority WRITE ;

local:
	LOCAL | ;

low_priority:
	 | | | | | | | | | LOW_PRIORITY ;
	# Only 10 %

sql_buffer_result:
	SQL_BUFFER_RESULT | ;

sql_cache:
	SQL_CACHE | SQL_NO_CACHE | ;

low_priority_delayed_high_priority:
	 | | | | | | | | | | | | | | | | | | | | | | | | | | | LOW_PRIORITY | DELAYED | HIGH_PRIORITY ;
	# Only 10 %
	# DELAYED removed because of Bug#45067

low_priority_delayed:
	 | | | | | | | | | | | | | | | | | | LOW_PRIORITY | DELAYED ;
	# Only 10 %
	# DELAYED removed because of Bug#45067

ignore:
	 | | | | | | | | | IGNORE ;
	# Only 10 %

