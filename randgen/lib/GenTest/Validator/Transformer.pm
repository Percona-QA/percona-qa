package GenTest::Validator::Transformer;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Transformer;
use GenTest::Comparator;
use GenTest::Simplifier::SQL;
use GenTest::Simplifier::Test;

my @transformer_names;

sub BEGIN {
	@transformer_names = (
		'Distinct',
		'Having',
		'LimitDecrease',
		'LimitIncrease',
		'OrderBy',
		'StraightJoin'
	);

	say("Transformer Validator will use the following Transformers: ".join(', ', @transformer_names));
}

sub validate {
	my ($validator, $executors, $results) = @_;

	my $executor = $executors->[0];
	my $original_result = $results->[0];
	my $original_query = $original_result->query();

	return STATUS_WONT_HANDLE if $original_query !~ m{^\s*SELECT}sio;
	return STATUS_WONT_HANDLE if defined $results->[0]->warnings();
	return STATUS_WONT_HANDLE if $results->[0]->status() != STATUS_OK;

	my $max_transformer_status; 
	foreach my $transformer_name (@transformer_names) {
		my $transformer_status = $validator->transform($transformer_name, $executors, $results);
		$max_transformer_status = $transformer_status if $transformer_status > $max_transformer_status;
	}

	return $max_transformer_status > STATUS_SELECT_REDUCTION ? $max_transformer_status - STATUS_SELECT_REDUCTION : $max_transformer_status;
}

sub transform {
	my ($validator, $transformer_name, $executors, $results) = @_;

	my $executor = $executors->[0];
	my $original_result = $results->[0];
	my $original_query = $original_result->query();

	my $transformer = GenTest::Transformer->new(
		class => 'GenTest::Transform::'.$transformer_name
	);

	my $transformed_query = $transformer->transform($original_query);
	
	return $transformed_query if $transformed_query =~ m{^\d+$}sgio;

	my $result_transformed = $executor->execute($transformed_query);
	my $transform_outcome = $transformer->validate([ $original_result, $result_transformed ]);

	return STATUS_OK if $transform_outcome == STATUS_OK;

	say("Query $original_query failed transformation with Transformer $transformer_name");

	my $simplifier_query = GenTest::Simplifier::SQL->new(
		oracle => sub {
			my $oracle_query = shift;
			my $oracle_result = $executor->execute($oracle_query, 1);
			return ORACLE_ISSUE_NO_LONGER_REPEATABLE if $oracle_result->status() != STATUS_OK;

			my $oracle_transformed_query = $transformer->transform($oracle_query);
			return ORACLE_ISSUE_NO_LONGER_REPEATABLE if $oracle_transformed_query == STATUS_WONT_HANDLE;

			my $oracle_transformed_result = $executor->execute($oracle_transformed_query, 1);
			return ORACLE_ISSUE_NO_LONGER_REPEATABLE if $oracle_transformed_result->status() != STATUS_OK;

			my $oracle_outcome = $transformer->validate([ $oracle_result, $oracle_transformed_result ]);

			if (
				($oracle_outcome == STATUS_CONTENT_MISMATCH) ||
				($oracle_outcome == STATUS_LENGTH_MISMATCH)
			) {
				return ORACLE_ISSUE_STILL_REPEATABLE;
			} else {
				return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
			}
		}
	);
	
	my $simplified_query = $simplifier_query->simplify($original_query);

	my $simplified_result = $executor->execute($simplified_query);
	if (defined $simplified_result->warnings()) {
		say("Simplified query produced warnings, will not dump a test case.");
		return STATUS_WONT_HANDLE;
	}

	if (not defined $simplified_query) {
		say("Simplification failed -- failure is likely sporadic.");
		return STATUS_WONT_HANDLE;
	}

	say("Simplified query is: $simplified_query");

	my $simplified_transformed_query = $transformer->transform($simplified_query);
	say("Simplified transformed query is: $simplified_transformed_query");

	my $simplified_transformed_result = $executor->execute($simplified_transformed_query);
	if (defined $simplified_transformed_result->warnings()) {
		say("Simplified transformed query produced warnings, will not dump a test case.");
		return STATUS_WONT_HANDLE;
	}

	say(GenTest::Comparator::dumpDiff($simplified_result, $simplified_transformed_result));

	my $simplifier_test = GenTest::Simplifier::Test->new(
		executors => [ $executor ],
		queries => [ $simplified_query, $simplified_transformed_query ]
	);

	my $test = $simplifier_test->simplify();

	my $testfile = tmpdir()."/".time().".test";
	open (TESTFILE , ">$testfile");
	print TESTFILE $test;
	close (TESTFILE);
	
	say("Test dumped to $testfile");

	return $transform_outcome;
}

1;
