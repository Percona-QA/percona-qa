package GenTest::Transform::StraightJoin;

use strict;
use lib 'lib';
use GenTest::Constants;

sub transform {
	my ($class, $orig_query) = @_;

	if ($orig_query =~ m{DISTINCT|DISTINCTROW|ALL}io) {
		return STATUS_WONT_HANDLE;
	} elsif ($orig_query =~ m{SELECT\s+STRAIGHT_JOIN}io) {
		$orig_query =~ s{STRAIGHT_JOIN}{}sio;
		return $orig_query."  /* TRANSFORM_OUTCOME_UNORDERED_MATCH */";
	} else {
		$orig_query =~ s{SELECT}{SELECT STRAIGHT_JOIN}sgio;
		return $orig_query."  /* TRANSFORM_OUTCOME_UNORDERED_MATCH */";
	}
}

1;
