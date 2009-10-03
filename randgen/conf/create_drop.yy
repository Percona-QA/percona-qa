query_init:
	create ; create ; create ; create ; create ; create ; create ; create ; create ; create ;

query:
	dml | dml | dml |
	dml | dml | dml |
	dml | dml | dml |
	ddl;

ddl:
	create | create | create | create | drop ;

dml:
	select;

select:
	SELECT * FROM pick_existing_table ;

create:
	CREATE TABLE IF NOT EXISTS pick_create_table (F1 INTEGER) ;

drop:
	DROP TABLE IF EXISTS pick_drop_table ;

pick_create_table:
	{ if (scalar(@dropped_tables) > 0) { $created_table = shift @dropped_tables } else { $created_table = $prng->letter() } ; push @created_tables, $created_table ; $created_table } ;

pick_drop_table:
	{ if (scalar(@created_tables) > 0) { $dropped_table = pop @created_tables } else { $dropped_table = $prng->letter() } ; push @dropped_tables, $dropped_table ; $dropped_table } ;

pick_existing_table:
	{ if (scalar(@created_tables) > 0) { $prng->arrayElement(\@created_tables) } else { $prng->letter() } } ;
