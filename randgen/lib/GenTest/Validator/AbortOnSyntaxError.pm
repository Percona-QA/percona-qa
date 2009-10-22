package GenTest::Validator::AbortOnSyntaxError;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;

1;

sub validate {
        my ($validator, $executors, $results) = @_;

	if ($results->[0]->status() == STATUS_SYNTAX_ERROR) {
		return STATUS_ENVIRONMENT_FAILURE;
	} else {
		return STATUS_WONT_HANDLE;
	}
}

1;
