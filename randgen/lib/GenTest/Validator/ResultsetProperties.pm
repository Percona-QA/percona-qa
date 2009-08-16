package GenTest::Validator::ResultsetProperties;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;
use Data::Dumper;

sub validate {
	my ($validator, $executors, $results) = @_;

	my $executor = $executors->[0];
	my $result = $results->[0];
	my $query = $result->query();

	return STATUS_WONT_HANDLE if $query !~ m{RESULTSET}sio;

	if (
		($query =~ m{RESULTSET_SAME_DATA_IN_EVERY_ROW}sio) &&
		(defined $result->data()) &&
		($result->rows() > 1)
	) {
		my %data_hash;
		foreach my $row (@{$result->data()}) {
			my $data_item = join('<field>', @{$row});
			$data_hash{$data_item}++;
		}
		if (keys(%data_hash) > 1) {
			say("Resultset from query: $query does not have the RESULTSET_SAME_DATA_IN_EVERY_ROW property - ".(keys(%data_hash))." distinct rows returned.");
			print Dumper $result;
			return STATUS_CONTENT_MISMATCH;
		}
	} elsif (
		($query =~ m{RESULTSET_ZERO_OR_ONE_ROWS}sio) &&
		($result->rows() > 1) 
	) {
		say("Resultset from query: $query does not have the RESULTSET_ZERO_OR_ONE_ROWS property - ".($result->rows())." rows returned.");
		print Dumper $result->data();
		return STATUS_LENGTH_MISMATCH;
	} elsif (
		($query =~ m{RESULTSET_SINGLE_INTEGER_ONE}sio) &&
		(defined $result->data()) && 
		($result->rows() == 1) &&
		($#{$result->data()} == 0) &&
		($#{$result->data()->[0]} == 0) &&
		($result->data()->[0]->[0] == 1)
	) {
		say("Resultset from query: $query does not have the RESULTSET_SINGLE_INTEGER_ONE property.");
		print Dumper $result->data();
		return STATUS_CONTENT_MISMATCH;
	}

	return STATUS_OK;
}

1;
