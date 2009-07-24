$combinations = [
	[
	'
		--engine=Falcon
		--reporters=Deadlock,ErrorLog,Backtrace,Recovery,Shutdown
		--mysqld=--loose-falcon-lock-wait-timeout=1
		--mysqld=--loose-innodb-lock-wait-timeout=1
		--mysqld=--log-output=none
		--mysqld=--skip-safemalloc
	'],
	[
		'--mysqld=--transaction-isolation=READ-UNCOMMITTED',
		'--mysqld=--transaction-isolation=READ-COMMITTED',
		'--mysqld=--transaction-isolation=REPEATABLE-READ',
		'--mysqld=--transaction-isolation=SERIALIZABLE'
	],
	[
		'--mysqld=--falcon-page-size=2K',
		'--mysqld=--falcon-page-size=4K',
		'--mysqld=--falcon-page-size=8K',
		'--mysqld=--falcon-page-size=16K',
		'--mysqld=--falcon-page-size=32K'
	],
	[
		'--mem',
		''
	],
	[
		'--rows=10',
		'--rows=100',
		'--rows=1000',
		'--rows=10000'
	],
	[
		'--threads=4',
		'--threads=8',
		'--threads=16',
		'--threads=32',
		'--threads=64'
	],
	[
		'--mysqld=--falcon-checkpoint-schedule=\'1 1 1 1 1\'',
		'--mysqld=--falcon-checkpoint-schedule=\'1 * * * *\'',
		'--mysqld=--falcon-consistent=read=1',
		'--mysqld=--falcon-gopher-threads=1',
		'--mysqld=--falcon-index-chill-threshold=1',
		'--mysqld=--falcon-record-chill-threshold=1',
		'--mysqld=--falcon-io-threads=1',
		'--mysqld=--falcon-page-cache-size=1K',
#		'--mysqld=--falcon-record-memory-max=3M',
		'--mysqld=--falcon-scavenge-schedule=\'1 1 1 1 1\'',
		'--mysqld=--falcon-scavenge-schedule=\'1 * * * *\'',
		'--mysqld=--falcon-serial-log-buffers=1',
		'--mysqld=--falcon-use-deferred-index-hash=1',
		'--mysqld=--falcon-use-supernodes=0'
	]
];
