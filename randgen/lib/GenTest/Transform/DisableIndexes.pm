package GenTest::Transform::DisableIndexes;

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

	my $tables = $executor->metaTables();

	my $alter_disable = join('; ', map { "ALTER TABLE $_ DISABLE KEYS" } @$tables);
	my $alter_enable = join('; ', map { "ALTER TABLE $_ ENABLE KEYS" } @$tables);

	return [
		$alter_disable,
		$original_query." /* TRANSFORM_OUTCOME_UNORDERED_MATCH */",
		$alter_enable
	];
}

1;
