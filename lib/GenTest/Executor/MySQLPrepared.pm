package GenTest::Executor::MySQLPrepared;

require Exporter;

@ISA = qw(GenTest::Executor GenTest::Executor::MySQL);

use strict;
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Executor;
use GenTest::Executor::MySQL;

1;

sub execute {
	my ($executor, $query) = @_;

	my $statement_id = 'statement'.abs($$);
	my $prepare_result = GenTest::Executor::MySQL::execute($executor, "PREPARE $statement_id FROM '$query'");
	return $prepare_result if $prepare_result->status() > STATUS_OK;
	
	my $execute_result = $executor->SUPER::execute("EXECUTE $statement_id");
	$execute_result->[GenTest::Result::RESULT_QUERY] = $query;

	$executor->SUPER::execute("DEALLOCATE PREPARE $statement_id");
		
	return $execute_result;
}

1;
