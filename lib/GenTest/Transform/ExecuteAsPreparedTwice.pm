package GenTest::Transform::ExecuteAsPreparedTwice;

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
		"CREATE DATABASE IF NOT EXISTS prepstmt_twice_db",
		"PREPARE prepstmt_twice_db.prep_stmt_$$ FROM $original_query",
		"EXECUTE prpstmt_twice_db.prep_stmt_$$ /* TRANSFORM_OUTCOME_UNORDERED_MATCH */",
                "EXECUTE prpstmt_twice_db.prep_stmt_$$ /* TRANSFORM_OUTCOME_UNORDERED_MATCH */",
		"DROP PREPARE prpstmt_twice_db.prep_stmt_$$"
	];
}

1;
