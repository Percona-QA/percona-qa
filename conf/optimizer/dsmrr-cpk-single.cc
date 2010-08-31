$combinations = [
	['
		--queries=1M --duration=180 --threads=1 --seed=time
		--reporter=QueryTimeout,Deadlock,Backtrace,ErrorLog --validator=Transformer --filter=conf/optimizer/dsmrr-cpk.ff
	'],
	['', '--notnull'],
	['', '--views'],
	[
		'--engine=MyISAM',
		'--engine=Maria',
		'--engine=Memory',
		'--engine=InnoDB',
		'--engine=InnoDB',
		'--engine=PBXT'
	],[
		'--mysqld=--join_cache_level=5',
		'--mysqld=--join_cache_level=6',
		'--mysqld=--join_cache_level=7',
		'--mysqld=--join_cache_level=8'
	],[
		'',
		'--mysqld=--join_buffer_size=1',
		'--mysqld=--join_buffer_size=100',
		'--mysqld=--join_buffer_size=1K',
		'--mysqld=--join_buffer_size=10K',
		'--mysqld=--join_buffer_size=100K'
	],[
		'--grammar=conf/optimizer/optimizer_no_subquery.yy',
		'--grammar=conf/optimizer/outer_join.yy --gendata=conf/optimizer/outer_join.zz',
		'--grammar=conf/optimizer/range_access.yy --gendata=conf/optimizer/range_access.zz'
	]
];
