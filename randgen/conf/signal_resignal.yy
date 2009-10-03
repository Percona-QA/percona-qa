query:
	set_variable | update |
	create_procedure | create_procedure | create_function | create_function |
	drop_procedure | drop_function |
	call_procedure | call_procedure ;

create_procedure:
	CREATE PROCEDURE procedure_name ( arg1 variable_type , arg2 variable_type , arg3 variable_type ) BEGIN procedure ; END ;

create_function:
	CREATE FUNCTION function_name ( arg1 variable_type, arg2 variable_type , arg3 variable_type) RETURNS variable_type BEGIN procedure ; RETURN value ; END ;

drop_function:
	DROP FUNCTION function_name ;

procedure:
	declare_variable ; declare_condition ; declare_handler ; procedure_statement ; procedure_statement ; procedure_statement ; procedure_statement ; procedure_statement ;

declaration:
	declare_handler |
	declare_condition |
	declare_variable ;

drop_procedure:
	DROP PROCEDURE procedure_name ;

call_procedure:
	CALL procedure_name ( value , value , value ) ;

procedure_name:
	p1 | p2 | p3 ;

function_name:
	f1 | f2 | f3 ;

procedure_statement:
	set_variable |
	signal_resignal |
	if |
	call_procedure |
	update ;

update:
	UPDATE _table SET _field = value ;

if:
	IF variable_name = value THEN signal_resignal ; ELSEIF variable_name = value THEN signal_resignal ; ELSE signal_resignal ; END IF ;

declare_variable:
	DECLARE variable_name variable_type default_value;

set_variable:
	SET at_variable_name = value ;

value:
	_english |
	_digit |
	at_variable_name |
	function_name ( _english , _digit , at_variable_name ) ;

variable_name:
	var1 ;
#| var2 | var3 ;

at_variable_name:
	@var1 ;
#| @var2 | @var3 ;

variable_type:
	INTEGER | VARCHAR(32) ;

default_value:
	| DEFAULT _english | DEFAULT _digit ;

declare_condition:
	DECLARE condition_name CONDITION FOR SQLSTATE value_keyword sqlstate_value ;

condition_name:
	cond1 ;
#| cond2 | cond3 ;

signal_resignal:
	signal_resignal_keyword signal_condition_value SET signal_list ;

signal_resignal_keyword:
	SIGNAL | RESIGNAL ;

signal_list:
	signal_item |
	signal_item , signal_item ;

signal_condition_value:
	SQLSTATE value_keyword sqlstate_value |
	condition_name ;

value_keyword:
	;
#
#	| VALUE ;

signal_item:
	signal_information ;

signal_information:
	condition_information_item = simple_value_specification ;

declare_handler:
	DECLARE handler_type HANDLER FOR handler_condition_list procedure_statement ;

handler_type:
	CONTINUE | EXIT ;
#| ;UNDO ;

handler_condition_list:
	condition_value |
	condition_value , condition_value ;

condition_value:
	SQLSTATE value_keyword sqlstate_value
	| condition_name
	| SQLWARNING
	| NOT FOUND
	| SQLEXCEPTION
#	| mysql_error_code	# not supported by signal/resignal
;

condition_information_item:
	CLASS_ORIGIN
	| SUBCLASS_ORIGIN
	| CONSTRAINT_CATALOG
	| CONSTRAINT_SCHEMA
	| CONSTRAINT_NAME
	| CATALOG_NAME
	| SCHEMA_NAME
	| TABLE_NAME
	| COLUMN_NAME
	| CURSOR_NAME
	| MESSAGE_TEXT
	| MYSQL_ERRNO
;

simple_value_specification:
	_english |
	_digit |
	variable_name |
	at_variable_name ;
	
#resignal:
#;

mysql_error_code:
	0 | 
	1022 | # ER_DUP_KEY
	1062 | # ER_DUP_ENTRY
	1106 | # ER_UNKNOWN_PROCEDURE
	1319 # ER_SP_COND_MISMATCH 
;

sqlstate_value:
'42000'	| # generic
'HY000'	| # generic
'23000' # duplicate value
;

_table:
	B | C ;
