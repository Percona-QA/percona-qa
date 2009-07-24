package GenTest::Transform::Distinct;

use strict;
use lib 'lib';
use GenTest::Constants;

sub transform {
	my ($class, $orig_query) = @_;

	# At this time we do not handle LIMIT because it may cause
	# both duplicate elimination AND extra rows to appear

	return STATUS_WONT_HANDLE if $orig_query =~ m{LIMIT}io;

	if ($orig_query =~ m{SELECT\s+DISTINCT}io) {
		$orig_query =~ s{SELECT\s+DISTINCT}{SELECT }io;
		return $orig_query." /* TRANSFORM_OUTCOME_SUPERSET */ ";
	} else {
		$orig_query =~ s{SELECT}{SELECT DISTINCT}io;
		return $orig_query." /* TRANSFORM_OUTCOME_DISTINCT */ ";
	}
}

1;
