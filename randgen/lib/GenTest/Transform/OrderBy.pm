package GenTest::Transform::OrderBy;

require Exporter;
@ISA = qw(GenTest GenTest::Transform);

use strict;
use lib 'lib';

use GenTest;
use GenTest::Transform;
use GenTest::Constants;


sub transform {
	my ($class, $original_query) = @_;

	if (
		($original_query !~ m{ORDER\s+BY}io) ||
		($original_query =~ m{GROUP\s+BY}io)
	) {
		return STATUS_WONT_HANDLE;
	} else {
		my $transform_outcome;
		if ($original_query =~ m{LIMIT[^()]*$}sio) {
			$transform_outcome = "TRANSFORM_OUTCOME_SUPERSET";
		} else {
			$transform_outcome = "TRANSFORM_OUTCOME_UNORDERED_MATCH";
		}

		$original_query =~ s{ORDER\s+BY[^()]*$}{}sio;
		return $original_query." /* $transform_outcome */ ";
	}
}

1;
