$combinations = [
	['--queries=1M --duration=180 --threads=1 --reporter=QueryTimeout,Backtrace,ErrorLog,Deadlock  --filter=conf/optimizer/dsmrr-cpk.ff'],
	['--notnull', ''],
	['--views', ''],
	[
		'--engine=MyISAM',
		'--engine=Maria',
		'--engine=Memory',
		'--engine=InnoDB',
		'--engine=InnoDB',
		'--engine=PBXT',
	],[
		'--mysqld1=--join_cache_level=5 --mysqld2=--join_cache_level=5',
		'--mysqld1=--join_cache_level=6 --mysqld2=--join_cache_level=6',
		'--mysqld1=--join_cache_level=7 --mysqld2=--join_cache_level=7',
		'--mysqld1=--join_cache_level=8 --mysqld2=--join_cache_level=8'
	],[
		'',
		'--mysqld1=--join_buffer_size=1 --mysqld2=--join_buffer_size=1',
		'--mysqld1=--join_buffer_size=100 --mysqld2=--join_buffer_size=100',
		'--mysqld1=--join_buffer_size=1K --mysqld2=--join_buffer_size=1K',
		'--mysqld1=--join_buffer_size=10K --mysqld2=--join_buffer_size=10K',
		'--mysqld1=--join_buffer_size=100K --mysqld2=--join_buffer_size=100K'
	],[
		'
			--basedir2=/home/philips/bzr/maria-5.3
			--validator=ResultsetComparatorSimplify
		',
	],[
		'--grammar=conf/optimizer/optimizer_no_subquery.yy',
		'--grammar=conf/optimizer/outer_join.yy --gendata=conf/optimizer/outer_join.zz',
		'--grammar=conf/optimizer/range_access.yy --gendata=conf/optimizer/range_access.zz'
	]
];
