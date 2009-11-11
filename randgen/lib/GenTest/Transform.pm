package GenTest::Transform;

require Exporter;
@ISA = qw(GenTest);

use strict;

use lib 'lib';
use GenTest;
use GenTest::Constants;

use constant TRANSFORMER_QUERIES_PROCESSED	=> 0;
use constant TRANSFORMER_QUERIES_TRANSFORMED	=> 1;

use constant TRANSFORM_OUTCOME_EXACT_MATCH	=> 1001;
use constant TRANSFORM_OUTCOME_UNORDERED_MATCH	=> 1002;
use constant TRANSFORM_OUTCOME_SUPERSET		=> 1003;
use constant TRANSFORM_OUTCOME_SUBSET		=> 1004;
use constant TRANSFORM_OUTCOME_SINGLE_ROW	=> 1005;
use constant TRANSFORM_OUTCOME_FIRST_ROW	=> 1006;
use constant TRANSFORM_OUTCOME_DISTINCT		=> 1007;
use constant TRANSFORM_OUTCOME_COUNT		=> 1008;
use constant TRANSFORM_OUTCOME_CUSTOM		=> 1009;

my %transform_outcomes = (
	'TRANSFORM_OUTCOME_EXACT_MATCH'		=> 1001,
	'TRANSFORM_OUTCOME_UNORDERED_MATCH'	=> 1002,
	'TRANSFORM_OUTCOME_SUPERSET'		=> 1003,
	'TRANSFORM_OUTCOME_SUBSET'		=> 1004,
	'TRANSFORM_OUTCOME_SINGLE_ROW'		=> 1005,
	'TRANSFORM_OUTCOME_FIRST_ROW'		=> 1006,
	'TRANSFORM_OUTCOME_DISTINCT'		=> 1007,
	'TRANSFORM_OUTCOME_COUNT'		=> 1008,
	'TRANSFORM_OUTCOME_CUSTOM'		=> 1009
);

sub transformExecuteValidate {
	my ($transformer, $original_query, $original_result, $executor) = @_;

	$transformer->[TRANSFORMER_QUERIES_PROCESSED]++;

	my $transformed_query = $transformer->transform($original_query, $executor);
	my $result_transformed;

	if (
		($transformed_query eq STATUS_OK) ||
		($transformed_query == STATUS_WONT_HANDLE)
	) {
		return STATUS_OK;
	} elsif ($transformed_query =~ m{^\d+$}sgio) {
		return $transformed_query;
	} elsif (ref($transformed_query) eq 'ARRAY') {
		# If the Transformer returned several queries, execute each one independently
		# and pick the first result set that was returned and use it during further processing.

		foreach my $transformed_query_part (@$transformed_query) {
			my $part_result = $executor->execute($transformed_query_part, 1);
			$result_transformed = $part_result if defined $part_result->data();
		}
	
		# Join the separate queries together for further printing and analysis

		$transformed_query = join('; ',@$transformed_query);
	} else {
		$result_transformed = $executor->execute($transformed_query, 1);
	}

	$transformer->[TRANSFORMER_QUERIES_TRANSFORMED]++;

	my $transform_outcome = $transformer->validate([ $original_result, $result_transformed ]);

	return ($transform_outcome, $transformed_query, $result_transformed);
}

sub validate {
	my ($transformer, $results) = @_;

	foreach my $result (@$results) {
		# Account for the fact that the transformed query may have failed
		return STATUS_OK if not defined $result;
		return STATUS_OK if not defined $result->data();
	}

	my $transformed_query = $results->[1]->query();

	my $transform_outcome = TRANSFORM_OUTCOME_CUSTOM;

	foreach my $potential_outcome (keys %transform_outcomes) {
		if ($transformed_query =~ m{$potential_outcome}s) {
			$transform_outcome = $transform_outcomes{$potential_outcome};
			last;
		}
	}

	if ($transform_outcome == TRANSFORM_OUTCOME_SINGLE_ROW) {
		return $transformer->isSingleRow($results);
	} elsif ($transform_outcome == TRANSFORM_OUTCOME_DISTINCT) {
		return $transformer->isDistinct($results);
	} elsif ($transform_outcome == TRANSFORM_OUTCOME_UNORDERED_MATCH) {
		return GenTest::Comparator::compare($results->[0], $results->[1]);
	} elsif ($transform_outcome == TRANSFORM_OUTCOME_SUPERSET) {
		return $transformer->isSuperset($results);
	} elsif ($transform_outcome == TRANSFORM_OUTCOME_FIRST_ROW) {
		return $transformer->isFirstRow($results);
	} elsif ($transform_outcome == TRANSFORM_OUTCOME_COUNT) {
		return $transformer->isCount($results);
	} else {
		die ("Unknown transform_outcome = $transform_outcome.");
	}
}

sub isFirstRow {
	my ($transformer, $results) = @_;

	if (
		($results->[1]->rows() == 0) &&
		($results->[0]->rows() == 0)
	) {
		return STATUS_OK;
	} else {
		my $row1 = join('<col>', @{$results->[0]->data()->[0]}) if defined $results->[0]->data();
		my $row2 = join('<col>', @{$results->[1]->data()->[0]}) if defined $results->[1]->data();
		return STATUS_CONTENT_MISMATCH if $row1 ne $row2;
	}
	return STATUS_OK;
}

sub isDistinct {
	my ($transformer, $results) = @_;

	my @rows;

	foreach my $i (0..1) {
		foreach my $row_ref (@{$results->[$i]->data()}) {
			my $row = join('<col>', @$row_ref);
			$rows[$i]->{$row}++;
			return STATUS_LENGTH_MISMATCH if $rows[$i]->{$row} > 1 && $i == 1;
		}
	}
	
	my $distinct_original = join ('<row>', sort keys %{$rows[0]} );
	my $distinct_transformed = join ('<row>', sort keys %{$rows[1]} );

	if ($distinct_original ne $distinct_transformed) {
		return STATUS_CONTENT_MISMATCH;
	} else {
		return STATUS_OK;
	}
}

sub isSuperset {
	my ($transformer, $results) = @_;
	my %rows;
	foreach my $row_ref (@{$results->[0]->data()}) {
		my $row = join('<col>', @$row_ref);
		$rows{$row}++;
	}

	foreach my $row_ref (@{$results->[1]->data()}) {
		my $row = join('<col>', @$row_ref);
		$rows{$row}--;
	}

	foreach my $row (keys %rows) {
		return STATUS_LENGTH_MISMATCH if $rows{$row} > 0;
	}

	return STATUS_OK;
}

sub isSingleRow {
	my ($transformer, $results) = @_;

	if (
		($results->[1]->rows() == 0) &&
		($results->[0]->rows() == 0)
	) {
		return STATUS_OK;
	} elsif ($results->[1]->rows() == 1) {
		my $transformed_row = join('<col>', @{$results->[1]->data()->[0]});
		foreach my $original_row_ref (@{$results->[0]->data()}) {
			my $original_row = join('<col>', @$original_row_ref);
			return STATUS_OK if $original_row eq $transformed_row;
		}
		return STATUS_CONTENT_MISMATCH;
	} else {
		# More than one row, something is messed up
		return STATUS_LENGTH_MISMATCH;
	}
}

sub isCount {
	my ($transformer, $results) = @_;

	my ($large_result, $small_result) ;

	if (
		($results->[0]->rows() == 0) ||
		($results->[1]->rows() == 0)
	) {
		return STATUS_OK;
	} elsif (
		($results->[0]->rows() == 1) &&
		($results->[1]->rows() == 1)
	) {
		return STATUS_OK;
	} elsif (
		($results->[0]->rows() == 1) &&
		($results->[1]->rows() >= 1)
	) {
		$small_result = $results->[0];
		$large_result = $results->[1];
	} elsif (
		($results->[1]->rows() == 1) &&
		($results->[0]->rows() >= 1)
	) {
		$small_result = $results->[1];
		$large_result = $results->[0];
	} else {
		return STATUS_LENGTH_MISMATCH;
	}

	if ($large_result->rows() != $small_result->data()->[0]->[0]) {
		return STATUS_LENGTH_MISMATCH;
	} else {
		return STATUS_OK;
	}
}

sub name {
	my $transformer = shift;
	my ($name) = $transformer =~ m{.*::([a-z]*)}sgio;
	return $name;
}

sub DESTROY {
	my $transformer = shift;
	print "# $transformer: queries_processed: ".$transformer->[TRANSFORMER_QUERIES_PROCESSED]."; queries_transformed: ".$transformer->[TRANSFORMER_QUERIES_TRANSFORMED]."\n" if rqg_debug();
}

1;
