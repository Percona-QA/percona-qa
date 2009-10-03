$combinations = [
	[
	'
		--grammar=conf/opt_grammar_b_exp.yy
		--queries=100K
		--threads=1
		--seed=time
		--mysqld=--init-file=/randgen/gentest-pcrews/mysql-test/gentest/init/no_materialization.sql
	'], [
		'--engine=INNODB',
		'--engine=MYISAM',
		'--engine=MEMORY'
	]
];
