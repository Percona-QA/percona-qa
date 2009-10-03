package GenTest::Transform::LimitDecrease;

require Exporter;
@ISA = qw(GenTest GenTest::Transform);

use strict;
use lib 'lib';

use GenTest;
use GenTest::Transform;
use GenTest::Constants;

sub transform {
	my ($class, $orig_query) = @_;

	if (my ($orig_limit) = $orig_query =~ m{LIMIT (\d+)}sio) {
		return STATUS_WONT_HANDLE if $orig_limit == 0;
		$orig_query =~ s{LIMIT \d+}{LIMIT 1}sio;
	} else {
		$orig_query .= " LIMIT 1 ";
	}

	if ($orig_query =~ m{TOTAL_ORDERING}sio) {
		return $orig_query." /* TRANSFORM_OUTCOME_FIRST_ROW */";
	} else {
		return $orig_query." /* TRANSFORM_OUTCOME_SINGLE_ROW */";
	}
}

1;
