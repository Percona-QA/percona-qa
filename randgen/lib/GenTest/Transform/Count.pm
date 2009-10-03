package GenTest::Transform::Count;

require Exporter;
@ISA = qw(GenTest GenTest::Transform);

use strict;
use lib 'lib';

use GenTest;
use GenTest::Transform;
use GenTest::Constants;

#
# This Transform provides the following transformations
# 
# SELECT COUNT(*) FROM ... -> SELECT * FROM ...
#
# SELECT ... FROM ... -> SELECT COUNT(*) FROM ...
#
# It avoids GROUP BY and any other aggregate functions because
# those are difficult to validate with a simple check such as 
# TRANSFORM_OUTCOME_COUNT
#

sub transform {
	my ($class, $orig_query) = @_;

	return STATUS_WONT_HANDLE if $orig_query =~ m{GROUP\s+BY|LIMIT|HAVING}sio;

#	print "A: $orig_query\n";

	my ($select_list) = $orig_query =~ m{SELECT (.*?) FROM}sio;

	if ($select_list =~ m{AVG|BIT|DISTINCT|GROUP|MAX|MIN|STD|SUM|VAR}sio) {
		return STATUS_WONT_HANDLE;
	} elsif ($select_list !~ m{COUNT}sio) {
		$orig_query =~ s{SELECT (.*?) FROM}{SELECT COUNT(*) , $1 FROM}sio;
	} elsif ($select_list =~ m{^\s*COUNT\(\s*\*\s*\)}sio) {
		$orig_query =~ s{SELECT .*? FROM}{SELECT * FROM}sio;
	} else {
		return STATUS_WONT_HANDLE;
	}

#	print "BBB: $orig_query\n";
	return $orig_query." /* TRANSFORM_OUTCOME_COUNT */";
}

1;
