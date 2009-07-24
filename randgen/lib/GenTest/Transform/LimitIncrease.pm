package GenTest::Transform::LimitIncrease;

use strict;
use lib 'lib';
use GenTest::Constants;

sub transform {
	my ($class, $orig_query) = @_;

	if ($orig_query =~ m{LIMIT}sio) {
		$orig_query =~ s{LIMIT \d+}{LIMIT 4294836225}sio;
		return $orig_query." /* TRANSFORM_OUTCOME_SUPERSET */";
	} else {
		return $orig_query." LIMIT 4294836225 /* TRANSFORM_OUTCOME_UNORDERED_MATCH */";
	}
}

1;
