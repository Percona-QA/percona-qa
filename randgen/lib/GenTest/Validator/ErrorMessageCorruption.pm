package GenTest::Validator::ErrorMessageCorruption;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;

use constant ASCII_ALLOWED_MIN	=> chr(32);  # space
use constant ASCII_ALLOWED_MAX  => chr(126); # tilde

1;

sub validate {
        my ($comparator, $executors, $results) = @_;
	my ($ascii_min, $ascii_max) = (ASCII_ALLOWED_MIN, ASCII_ALLOWED_MAX);
	foreach my $result (@$results) {
		if (
			(defined $result->errstr()) &&
			($result->errstr() =~ m{[^$ascii_min-$ascii_max\s]}siox )
		) {
			say("Error: '".$result->errstr()."' indicates memory corruption.");
			return STATUS_DATABASE_CORRUPTION;
		}
	}		

	return STATUS_OK;
}

1;
