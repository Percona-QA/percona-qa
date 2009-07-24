package GenTest::Validator::SelectStability;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use GenTest;
use GenTest::Comparator;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;
use Time::HiRes;

sub validate {
	my ($validator, $executors, $results) = @_;
	my $executor = $executors->[0];
	my $orig_result = $results->[0];
	my $orig_query = $orig_result->query();

	return STATUS_OK if $orig_query !~ m{^\s*select}io;
	return STATUS_OK if not defined $orig_result->data();

	foreach my $delay (0, 0.01, 0.1) {
		Time::HiRes::sleep($delay);
		my $new_result = $executor->execute($orig_query);
		return STATUS_OK if not defined $new_result->data();
		my $compare_outcome = GenTest::Comparator::compare($orig_result, $new_result);
		if ($compare_outcome > STATUS_OK) {
			say("Query: $orig_query; returns different result when executed after a delay of $delay seconds.");
			say(GenTest::Comparator::dumpDiff($orig_result, $new_result));
			return $compare_outcome - STATUS_SELECT_REDUCTION;
		}
	}

	return STATUS_OK;
}

1;
