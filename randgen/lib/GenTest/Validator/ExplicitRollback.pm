package GenTest::Validator::ExplicitRollback;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;

my $inconsistent_state = 0;

sub validate {
	my ($validator, $executors, $results) = @_;
	my $dsn = $executors->[0]->dsn();

	foreach my $i (0..$#$results) {
		if ($results->[$i]->status() == STATUS_TRANSACTION_ERROR) {
#			say("entering inconsistent state due to query".$results->[$i]->query());
			$inconsistent_state = 1;
		} elsif ($results->[$i]->query() =~ m{^\s*(COMMIT|START TRANSACTION|BEGIN)}sio) {
#			say("leaving inconsistent state due to query ".$results->[$i]->query());
			$inconsistent_state = 0;
		}

		if ($inconsistent_state == 1) {
#			say("Explicit rollback after query ".$results->[$i]->query());
			$executors->[$i]->dbh()->do("ROLLBACK /* Explicit ROLLBACK after a ".$results->[$i]->errstr()." error. */ ");
		}

	}
	
	return STATUS_OK;
}

1;
