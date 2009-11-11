package GenTest::Transform::ExecuteAsView;

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
		"CREATE DATABASE IF NOT EXISTS views_db",
		"CREATE OR REPLACE VIEW views_db.view_$$ AS $original_query",
		"SELECT * FROM views_db.view_$$ /* TRANSFORM_OUTCOME_UNORDERED_MATCH */",
		"DROP VIEW IF EXISTS views_db.view_$$"
	];
}

1;
