package GenTest::Transformer;

require Exporter;
@ISA = qw(GenTest);
@EXPORT = qw(
	TRANSFORM_MUST_BE_EXACT_MATCH
	TRANSFORM_MUST_BE_UNORDERED_MATCH
	TRANSFORM_MUST_BE_SUPERSET
	TRANSFORM_MUST_BE_SUBSET
	TRANSFORM_MUST_BE_SINGLE_ROW
	TRANSFORM_MUST_BE_FIRST_ROW
);

use strict;

use lib 'lib';
use GenTest;
use GenTest::Constants;

use constant TRANSFORMER_CLASS			=> 0;

use constant TRANSFORM_OUTCOME_EXACT_MATCH	=> 1001;
use constant TRANSFORM_OUTCOME_UNORDERED_MATCH	=> 1002;
use constant TRANSFORM_OUTCOME_SUPERSET		=> 1003;
use constant TRANSFORM_OUTCOME_SUBSET		=> 1004;
use constant TRANSFORM_OUTCOME_SINGLE_ROW	=> 1005;
use constant TRANSFORM_OUTCOME_FIRST_ROW	=> 1006;
use constant TRANSFORM_OUTCOME_DISTINCT		=> 1007;
use constant TRANSFORM_OUTCOME_CUSTOM		=> 1008;


my %transform_outcomes = (
	'TRANSFORM_OUTCOME_EXACT_MATCH'		=> 1001,
	'TRANSFORM_OUTCOME_UNORDERED_MATCH'	=> 1002,
	'TRANSFORM_OUTCOME_SUPERSET'		=> 1003,
	'TRANSFORM_OUTCOME_SUBSET'		=> 1004,
	'TRANSFORM_OUTCOME_SINGLE_ROW'		=> 1005,
	'TRANSFORM_OUTCOME_FIRST_ROW'		=> 1006,
	'TRANSFORM_OUTCOME_DISTINCT'		=> 1007,
	'TRANSFORM_OUTCOME_CUSTOM'		=> 1008
);
	
sub new {
        my $class = shift;
        my $transformer = $class->SUPER::new({
		'class'		=> TRANSFORMER_CLASS
        }, @_);

	eval "use ".$transformer->[TRANSFORMER_CLASS] or print $@;

	return $transformer;
}

sub transform {
	my ($transformer, $original_query) = @_;

	my $class = $transformer->class();

	return $class->transform($original_query);
}

sub validate {
	my ($transformer, $results) = @_;

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

sub class {
	return $_[0]->[TRANSFORMER_CLASS];
}

1;
