package GenTest::Executor::Postgres;

use GenTest;
use GenTest::Executor;
require Exporter;

@ISA = qw(GenTest::Executor);

use strict;
use DBI;

sub init {
	my $executor = shift;
	my $dbh =  DBI->connect($executor->dsn());
	$executor->setDbh($dbh);	
}

sub execute {
	my ($executor, $query) = @_;
	my $dbh = $executor->dbh();
	my $sth = $dbh->prepare($query);
	$sth->execute();
	return $sth->fetchall_arrayref();
}
