$combinations = [
	['
		--grammar=conf/metadata_locking.yy
		--gendata=conf/metadata_locking.zz
		--queries=100K
		--duration=600
		--basedir=/build/bzr/azalea-bugfixing
		--validator=ResultsetProperties
                --reporters=Deadlock,ErrorLog,Backtrace,Shutdown
		--mysqld=--innodb-lock-wait-timeout=1
		--mysqld=--transaction-isolation=REPEATABLE-READ
	'], [
		'--engine=MyISAM',
		'--engine=MEMORY',
		'--engine=Innodb'
	], [
		'--rows=1',
		'--rows=10',
		'--rows=100',
	],
	[
		'--threads=4',
		'--threads=8',
		'--threads=16',
		'--threads=32',
		'--threads=64',
		'--threads=128'
	]
];
