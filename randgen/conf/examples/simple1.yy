query:
	select_simple |
	select_with_where |
	select_with_comparison |
	select_multiple_columns ;

# ==============================================================================
# SIMPLE SELECT QUERIES
# ==============================================================================

select_simple:
	SELECT * FROM _table |
	SELECT _field FROM _table |
	SELECT _field , _field FROM _table ;

# ==============================================================================
# SELECT WITH WHERE CLAUSE
# ==============================================================================
# WHERE clause is critical for testing - ensures SELECT and INSERT...SELECT
# handle WHERE differently

select_with_where:
	SELECT * FROM _table WHERE condition |
	SELECT _field FROM _table WHERE condition |
	SELECT _field , _field FROM _table WHERE condition ;

# ==============================================================================
# SELECT WITH COMPARISON OPERATORS
# ==============================================================================
# Tests different comparison operators for consistency

select_with_comparison:
	SELECT * FROM _table WHERE _field = _digit |
	SELECT * FROM _table WHERE _field < _digit |
	SELECT * FROM _table WHERE _field > _digit |
	SELECT _field FROM _table WHERE _field != _digit ;

# ==============================================================================
# SELECT WITH MULTIPLE COLUMNS
# ==============================================================================
# Tests different column selections

select_multiple_columns:
	SELECT _field , _field FROM _table |
	SELECT _field , _field , _field FROM _table |
	SELECT * FROM _table ;

# ==============================================================================
# CONDITIONS - WHERE clause building blocks
# ==============================================================================
# Define common WHERE clause patterns

condition:
	_field = _digit |
	_field < _digit |
	_field > _digit |
	_field >= _digit |
	_field <= _digit |
	_field != _digit ;

