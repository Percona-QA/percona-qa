package GenTest::Transform::ExecuteAsSPTwice;

require Exporter;
@ISA = qw(GenTest GenTest::Transform);

use strict;
use lib 'lib';

use GenTest;
use GenTest::Transform;
use GenTest::Constants;

sub transform {
	my ($class, $original_query, $executor) = @_;

	return STATUS_WONT_HANDLE if $original_query !~ m{SELECT}io;

	return [
		"CREATE DATABASE IF NOT EXISTS sptwice_db",
		"CREATE PROCEDURE sptwice_db.stored_proc_$$ LANGUAGE SQL $original_query",
		"CALL sptwice_db.stored_proc_$$ /* TRANSFORM_OUTCOME_UNORDERED_MATCH */",
                "CALL sptwice_db.stored_proc_$$ /* TRANSFORM_OUTCOME_UNORDERED_MATCH */",
		"DROP PROCEDURE IF EXISTS sptwice_db.stored_proc_$$"
	];
}

1;
