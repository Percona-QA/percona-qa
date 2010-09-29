# Copyright (c) 2008,2010 Oracle and/or its affiliates. All rights reserved.
# Use is subject to license terms.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301
# USA

package GenTest::Transform;

require Exporter;
@ISA = qw(GenTest);

use strict;

use lib 'lib';
use GenTest;
use GenTest::Constants;
use Data::Dumper;

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
use constant TRANSFORM_OUTCOME_EMPTY_RESULT	=> 1009;
use constant TRANSFORM_OUTCOME_SINGLE_INTEGER_ONE	=> 1010;

my %transform_outcomes = (
	'TRANSFORM_OUTCOME_EXACT_MATCH'		=> 1001,
	'TRANSFORM_OUTCOME_UNORDERED_MATCH'	=> 1002,
	'TRANSFORM_OUTCOME_SUPERSET'		=> 1003,
	'TRANSFORM_OUTCOME_SUBSET'		=> 1004,
	'TRANSFORM_OUTCOME_SINGLE_ROW'		=> 1005,
	'TRANSFORM_OUTCOME_FIRST_ROW'		=> 1006,
	'TRANSFORM_OUTCOME_DISTINCT'		=> 1007,
	'TRANSFORM_OUTCOME_COUNT'		=> 1008,
	'TRANSFORM_OUTCOME_EMPTY_RESULT'	=> 1009,
	'TRANSFORM_OUTCOME_SINGLE_INTEGER_ONE'	=> 1010
);

sub transformExecuteValidate {
	my ($transformer, $original_query, $original_result, $executor) = @_;

	$transformer->[TRANSFORMER_QUERIES_PROCESSED]++;

	my $transformed_query = $transformer->transform($original_query, $executor, $original_result);
	my @transformed_queries;
	my @transformed_results;
	my $transform_outcome;

	if (
		($transformed_query eq STATUS_OK) ||
		($transformed_query == STATUS_WONT_HANDLE)
	) {
		return STATUS_OK;
	} elsif ($transformed_query =~ m{^\d+$}sgio) {
		return $transformed_query;	# Error was returned and no queries
	} elsif (ref($transformed_query) eq 'ARRAY') {
		# Transformer returned several queries, execute each one independently
		@transformed_queries = @$transformed_query;
	} else {
		@transformed_queries = ($transformed_query);
	}

	$transformed_queries[0] =  "/* ".ref($transformer)." */ ".$transformed_queries[0];

	foreach my $transformed_query_part (@transformed_queries) {
		my $part_result = $executor->execute($transformed_query_part);
		if (
			($part_result->status() == STATUS_SYNTAX_ERROR) || ($part_result->status() == STATUS_SEMANTIC_ERROR)
		) {
			say("Transform ".ref($transformer)." failed with a syntactic or semantic error.");
			say("Offending query is: $transformed_query_part;");
			say("Original query is: $original_query;");
			return STATUS_ENVIRONMENT_FAILURE;
		} elsif ($part_result->status() != STATUS_OK) {
			return $part_result->status();
		} elsif (defined $part_result->data()) {
			my $part_outcome = $transformer->validate($original_result, $part_result);
			$transform_outcome = $part_outcome if (($part_outcome > $transform_outcome) || (! defined $transform_outcome));

			push @transformed_results, $part_result if ($part_outcome != STATUS_WONT_HANDLE) && ($part_outcome != STATUS_OK);
		}
	}

	if (
		(not defined $transform_outcome) ||
		($transform_outcome == STATUS_WONT_HANDLE)
	) {
		say("Transform ".ref($transformer)." produced no query which could be validated ($transform_outcome).");
		say("The following queries were produced");
		print Dumper \@transformed_queries;
		return STATUS_ENVIRONMENT_FAILURE;
	} else {
		$transformer->[TRANSFORMER_QUERIES_TRANSFORMED]++;
		return ($transform_outcome, \@transformed_queries, \@transformed_results);
	}
}

sub validate {
	my ($transformer, $original_result, $transformed_result) = @_;

	my $transformed_query = $transformed_result->query();

	my $transform_outcome;

	foreach my $potential_outcome (keys %transform_outcomes) {
		if ($transformed_query =~ m{$potential_outcome}s) {
			$transform_outcome = $transform_outcomes{$potential_outcome};
			last;
		}
	}

	if ($transform_outcome == TRANSFORM_OUTCOME_SINGLE_ROW) {
		return $transformer->isSingleRow($original_result, $transformed_result);
	} elsif ($transform_outcome == TRANSFORM_OUTCOME_DISTINCT) {
		return $transformer->isDistinct($original_result, $transformed_result);
	} elsif ($transform_outcome == TRANSFORM_OUTCOME_UNORDERED_MATCH) {
		return GenTest::Comparator::compare($original_result, $transformed_result);
	} elsif ($transform_outcome == TRANSFORM_OUTCOME_SUPERSET) {
		return $transformer->isSuperset($original_result, $transformed_result);
	} elsif ($transform_outcome == TRANSFORM_OUTCOME_FIRST_ROW) {
		return $transformer->isFirstRow($original_result, $transformed_result);
	} elsif ($transform_outcome == TRANSFORM_OUTCOME_COUNT) {
		return $transformer->isCount($original_result, $transformed_result);
	} elsif ($transform_outcome == TRANSFORM_OUTCOME_EMPTY_RESULT) {
		return $transformer->isEmptyResult($original_result, $transformed_result);
	} elsif ($transform_outcome == TRANSFORM_OUTCOME_SINGLE_INTEGER_ONE) {
		return $transformer->isSingleIntegerOne($original_result, $transformed_result);
	} else {
		return STATUS_WONT_HANDLE;
	}
}

sub isFirstRow {
	my ($transformer, $original_result, $transformed_result) = @_;

	if (
		($original_result->rows() == 0) &&
		($transformed_result->rows() == 0)
	) {
		return STATUS_OK;
	} else {
		my $row1 = join('<col>', @{$original_result->data()->[0]});
		my $row2 = join('<col>', @{$transformed_result->data()->[0]});
		return STATUS_CONTENT_MISMATCH if $row1 ne $row2;
	}
	return STATUS_OK;
}

sub isDistinct {
	my ($transformer, $original_result, $transformed_result) = @_;

	my $original_rows;
	my $transformed_rows;

	foreach my $row_ref (@{$original_result->data()}) {
		my $row = lc(join('<col>', @$row_ref));
		$original_rows->{$row}++;
	}

	foreach my $row_ref (@{$transformed_result->data()}) {
		my $row = lc(join('<col>', @$row_ref));
		$transformed_rows->{$row}++;
		return STATUS_LENGTH_MISMATCH if $transformed_rows->{$row} > 1;
	}


	my $distinct_original = join ('<row>', sort keys %{$original_rows} );
	my $distinct_transformed = join ('<row>', sort keys %{$transformed_rows} );

	if ($distinct_original ne $distinct_transformed) {
		return STATUS_CONTENT_MISMATCH;
	} else {
		return STATUS_OK;
	}
}

sub isSuperset {
	my ($transformer, $original_result, $transformed_result) = @_;
	my %rows;

	foreach my $row_ref (@{$original_result->data()}) {
		my $row = join('<col>', @$row_ref);
		$rows{$row}++;
	}

	foreach my $row_ref (@{$transformed_result->data()}) {
		my $row = join('<col>', @$row_ref);
		$rows{$row}--;
	}

	foreach my $row (keys %rows) {
		return STATUS_LENGTH_MISMATCH if $rows{$row} > 0;
	}

	return STATUS_OK;
}

sub isSingleRow {
	my ($transformer, $original_result, $transformed_result) = @_;

	if (
		($original_result->rows() == 0) &&
		($transformed_result->rows() == 0)
	) {
		return STATUS_OK;
	} elsif ($transformed_result->rows() == 1) {
		my $transformed_row = join('<col>', @{$transformed_result->data()->[0]});
		foreach my $original_row_ref (@{$original_result->data()}) {
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
	my ($transformer, $original_result, $transformed_result) = @_;

	my ($large_result, $small_result) ;

	if (
		($original_result->rows() == 0) ||
		($transformed_result->rows() == 0)
	) {
		return STATUS_OK;
	} elsif (
		($original_result->rows() == 1) &&
		($transformed_result->rows() == 1)
	) {
		return STATUS_OK;
	} elsif (
		($original_result->rows() == 1) &&
		($transformed_result->rows() >= 1)
	) {
		$small_result = $original_result;
		$large_result = $transformed_result;
	} elsif (
		($transformed_result->rows() == 1) &&
		($original_result->rows() >= 1)
	) {
		$small_result = $transformed_result;
		$large_result = $original_result;
	} else {
		return STATUS_LENGTH_MISMATCH;
	}

	if ($large_result->rows() != $small_result->data()->[0]->[0]) {
		return STATUS_LENGTH_MISMATCH;
	} else {
		return STATUS_OK;
	}
}

sub isEmptyResult {
	my ($transformer, $original_result, $transformed_result) = @_;

	if ($transformed_result->rows() == 0) {
		return STATUS_OK;
	} else {
		return STATUS_LENGTH_MISMATCH;
	}
}

sub isSingleIntegerOne {
	my ($transformer, $original_result, $transformed_result) = @_;

	if (
		($transformed_result->rows() == 1) &&
		($#{$transformed_result->data()->[0]} == 0) &&
		($transformed_result->data()->[0]->[0] eq '1')
	) {
		return STATUS_OK;
	} else {
		use Data::Dumper;
		print Dumper $transformed_result;
		exit;
		return STATUS_LENGTH_MISMATCH;
	}


}

sub name {
	my $transformer = shift;
	my ($name) = $transformer =~ m{.*::([a-z]*)}sgio;
	return $name;
}

sub DESTROY {
	my $transformer = shift;
	print "# ".ref($transformer).": queries_processed: ".$transformer->[TRANSFORMER_QUERIES_PROCESSED]."; queries_transformed: ".$transformer->[TRANSFORMER_QUERIES_TRANSFORMED]."\n" if rqg_debug();
}

1;
