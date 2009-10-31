query_init:
	USE flightstats;

# The queries from this grammar can produce extremely long results
# to avoid excessive memory usage, we reduce all queries to a COUNT(*)
# This way, we also do not have to tinker with any field names in the SELECT list

query:
	{ $alias_count = 0 ; %tables = () ; %aliases = () ; return undef ; }
	SELECT COUNT(*)
	FROM join_list
	where
	LIMIT _tinyint_unsigned;

#
# We divide the joins into "big", those containing the `ontime` table, and 
# small, those containing stuff like states and ZIP codes.
#

join_list:
	big_join_item |
	( big_join_item ) JOIN ( small_join_item );

big_join_item:
	ontime2carriers | ontime2airport | aircraft2ontime ;
	
small_join_item:
	airport2state | airport2zipcode ;

#
# Here we define only joins that are meaningful, useful and
# very likely to use indexes.
#

ontime2carriers:
	ontime_table
	LEFT JOIN carrier_table
	ON ( previous_table . `carrier` = current_table . `code` );

ontime2airport:
	ontime_table
	LEFT JOIN airport_table
	ON ( previous_table . origin_destination = current_table .`code` );

origin_destination:
	`origin` | `destination` ;

aircraft2ontime:
	ontime_table
	LEFT JOIN aircraft_table
	ON ( current_table .`tail_num` = previous_table .`tail_num` );

airport2state:
	airport_table
	LEFT JOIN state_table
	ON ( previous_table . `state` = current_table . `state_code` );

airport2zipcode:
	airport_table
	LEFT JOIN zipcode_table
	ON ( previous_table . `state` = current_table . `state_code` );

ontime_table:
	`ontime_2005_12` { $table_name = 'ontime'; return undef;  } new_table;

carrier_table:
	`carriers` { $table_name = 'carriers'; return undef; } new_table;

airport_table:
	`airports` { $table_name = 'airports'; return undef; } new_table;

aircraft_table:
	`aircraft` { $table_name = 'aircraft'; return undef; } new_table;

state_table:
	`states` { $table_name = 'states' ; return undef; } new_table ;

zipcode_table:
	`zipcodes` { $table_name = 'zipcodes' ; return undef; } new_table ;

#
# We always have a WHERE and it contains a lot of expressions combined with an AND in order to provide
# numerous opportunities for optimization and reduce calculation times.
# In addition, we always define at least one condition against the `ontime` table.
#

where:
	WHERE
	{ $condition_table = 'ontime' ; return undef; } start_condition ontime_condition end_condition AND
	( where_list and_or where_list );

where_list:
	( where_condition ) | 
	( where_condition AND where_list ) |
	( where_condition AND where_list ) |
	( where_condition AND where_list ) ;

#
# Each of the conditions described below are valid and meaningful for the particular table in question
# They are likely to use indexes and/or zero down on a smaller number of records
# 

where_condition:
	{ $condition_table = 'ontime' ; return undef; } start_condition ontime_condition end_condition |
	{ $condition_table = 'carriers' ; return undef; } start_condition carrier_condition end_condition |
	{ $condition_table = 'aircraft'; return undef; } start_condition aircraft_condition end_condition |
	{ $condition_table = 'airports'; return undef; } start_condition airport_condition end_condition |
	{ $condition_table = 'states'; return undef; } start_condition state_condition end_condition |
	{ $condition_table = 'zipcodes'; return undef; } start_condition zipcode_condition end_condition ;

ontime_condition:
	table_alias . `carrier` generic_carrier_expression |
	table_alias . `origin` generic_char_expression |
	table_alias . `destination` generic_char_expression |
	table_alias . `tail_num` generic_char_expression ;

state_condition:
	table_alias . `state_code` generic_state_expression |
	table_alias . `name` generic_char_expression ;

zipcode_condition:
	table_alias . `zipcode` BETWEEN 10000 + ( _tinyint_unsigned * 100) AND 10000 + ( _tinyint_unsigned * 100) ;

table_alias:
	{ my $alias = shift @{$aliases{$condition_table}}; push @{$aliases{$condition_table}} , $alias ; return $alias } ;

carrier_condition:
	table_alias . `code` generic_carrier_expression;

generic_carrier_expression:
	= single_carrier |
	IN ( carrier_list ) ;

airport_condition:
	table_alias . `code` generic_char_expression |
	table_alias . `state` generic_state_expression |
	( table_alias . `state` generic_state_expression ) and_or ( table_alias . `city` generic_char_expression);

aircraft_condition:
	table_alias . `tail_num` generic_char_expression |
	table_alias . `state` generic_state_expression ;

generic_char_expression:
	BETWEEN _char[invariant] AND CHAR(ASCII( _char[invariant] ) + one_two ) ;

one_two:
	1 | 2 ;

generic_state_expression:
	= single_state |
	IN ( state_list ) |
	BETWEEN _char(2) AND _char(2) ;

state_list:
	single_state |
	single_state , state_list ;

carrier_list:
	single_carrier |
	single_carrier , carrier_list ;

single_state:
	'AK' | 'AL' | 'AR' | 'AS' | 'AZ' | 'CA' | 'CO' | 'CQ' | 'CT' | 'DC' | 'DE' | 'FL' | 'GA' | 'GU' | 'HI' | 'IA' | 'ID' | 'IL' | 'IN' | 'KS' | 'KY' | 'LA' | 'MA' | 'MD' | 'ME' | 'MI' | 'MN' | 'MO' | 'MQ' | 'MS' | 'MT' | 'NC' | 'ND' | 'NE' | 'NH' | 'NJ' | 'NM' | 'NV' | 'NY' | 'OH' | 'OK' | 'OR' | 'PA' | 'PR' | 'RI' | 'SC' | 'SD' | 'TN' | 'TX' | 'UT' | 'VA' | 'VI' | 'VT' | 'WA' | 'WI' | 'WQ' | 'WV' | 'WY' ;

single_carrier:
	'AA'|'AQ'|'AS'|'B6'|'CO'|'DH'|'DL'|'EV'|'FL'|'HA'|'HP'|'MQ'|'NW'|'OH'|'OO'|'RU'|'TW'|'TZ'|'UA'|'US'|'WN';

#
# When we define a condition, we check if the table for which this condition would apply is present in 
# the list of the tables we selected for joining. If the table is not present, the condition is still
# generated, but it is commented out in order to avoid "unknown table" errors.
#

start_condition:
	{ ((exists $tables{$condition_table}) ? '' : '/* ') } ;

end_condition:
	{ ((exists $tables{$condition_table}) ? '' : '*/ 1 = 1 ') };

new_table:
	AS { $alias_count++ ; $tables{$table_name}++ ; push @{$aliases{$table_name}}, 'a'.$alias_count ; return 'a'.$alias_count }  ;

current_table:
	{ 'a'.$alias_count };

previous_table:
	{ 'a'.($alias_count - 1) };
