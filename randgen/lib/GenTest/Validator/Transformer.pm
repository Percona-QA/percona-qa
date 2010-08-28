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

package GenTest::Validator::Transformer;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Comparator;
use GenTest::Simplifier::SQL;
use GenTest::Simplifier::Test;
use GenTest::Translator;
use GenTest::Translator::Mysqldump2ANSI;
use GenTest::Translator::Mysqldump2javadb;
use GenTest::Translator::MysqlDML2ANSI;

my @transformer_names;
my @transformers;

sub BEGIN {
	@transformer_names = (
		'DisableChosenPlan',
		'ConvertSubqueriesToViews',
		'Count',
#		'DisableIndexes',
		'Distinct',
		'ExecuteAsPreparedTwice',
		'ExecuteAsSPTwice',
		'ExecuteAsView',
		'ExecuteAsInsertSelect',
		'FromSubquery',
		'Having',
		'InlineSubqueries',
#		'InlineVirtualColumns',
		'LimitDecrease',
		'LimitIncrease',
		'OrderBy',
		'RemoveIndexHints',
		'StraightJoin'
	);

	say("Transformer Validator will use the following Transformers: ".join(', ', @transformer_names));

	foreach my $transformer_name (@transformer_names) {
		eval ("require GenTest::Transform::'".$transformer_name) or die $@;
		my $transformer = ('GenTest::Transform::'.$transformer_name)->new();
		push @transformers, $transformer;
	}
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
	foreach my $transformer (@transformers) {
		my $transformer_status = $validator->transform($transformer, $executor, $results);
		return $transformer_status if $transformer_status > STATUS_CRITICAL_FAILURE;
		$max_transformer_status = $transformer_status if $transformer_status > $max_transformer_status;
	}

	return $max_transformer_status > STATUS_SELECT_REDUCTION ? $max_transformer_status - STATUS_SELECT_REDUCTION : $max_transformer_status;
}

sub transform {
	my ($validator, $transformer, $executor, $results) = @_;

	my $original_result = $results->[0];
	my $original_query = $original_result->query();

	my ($transform_outcome, $transformed_queries, $transformed_results) = $transformer->transformExecuteValidate($original_query, $original_result, $executor);
	return $transform_outcome if ($transform_outcome > STATUS_CRITICAL_FAILURE) || ($transform_outcome eq STATUS_OK);

	say("Original query: $original_query failed transformation with Transformer ".$transformer->name());
	say("Transformed query: ".join('; ', @$transformed_queries));

	say(GenTest::Comparator::dumpDiff($original_result, $transformed_results->[0]));

	say("Simplifying...");

	my $simplifier_query = GenTest::Simplifier::SQL->new(
		oracle => sub {
			my $oracle_query = shift;
			my $oracle_result = $executor->execute($oracle_query, 1);

			return ORACLE_ISSUE_STATUS_UNKNOWN if $oracle_result->status() != STATUS_OK;

			my ($oracle_outcome, $oracle_transformed_queries, $oracle_transformed_results) = $transformer->transformExecuteValidate($oracle_query, $oracle_result, $executor);

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

	my $simplified_result = $executor->execute($simplified_query, 1);
	if (defined $simplified_result->warnings()) {
		say("Simplified query produced warnings.");
#		return STATUS_WONT_HANDLE;
	}

	if (not defined $simplified_query) {
		say("Simplification failed -- failure is likely sporadic.");
		return STATUS_WONT_HANDLE;
	}

	say("Simplified query: $simplified_query");

	my ($transform_outcome, $simplified_transformed_queries, $simplified_transformed_results) = $transformer->transformExecuteValidate($simplified_query, $simplified_result, $executor);

	$simplified_transformed_queries = join('; ', @$simplified_transformed_queries) if ref($simplified_transformed_queries) eq 'ARRAY';
	say("Simplified transformed query: $simplified_transformed_queries");

	if (defined $simplified_transformed_results->[0]->warnings()) {
		say("Simplified transformed query produced warnings.");
#		return STATUS_WONT_HANDLE;
	}

	say(GenTest::Comparator::dumpDiff($simplified_result, $simplified_transformed_results->[0]));

	my $simplifier_test = GenTest::Simplifier::Test->new(
		executors => [ $executor ],
		results => [ [ $simplified_result, $simplified_transformed_results->[0] ] ],
		queries => [ $simplified_query, $simplified_transformed_queries ]
	);

	my $test = $simplifier_test->simplify();

	my $testfile = tmpdir()."/".time().".test";
	open (TESTFILE , ">$testfile");
	print TESTFILE $test;
	close (TESTFILE);
	
	say("MySQL test dumped to $testfile");

    my $translator = GenTest::Translator::Mysqldump2javadb->new();
    my $javadbtest = $translator->translate($test);
    if ($javadbtest) {
        $translator = GenTest::Translator::MysqlDML2ANSI->new();
        $javadbtest = $translator->translate($javadbtest);
    }

    if ($javadbtest) {
        $testfile = tmpdir()."/".time()."-javadb.test";
        open (TESTFILE , ">$testfile");
        print TESTFILE $javadbtest;
        close (TESTFILE);
        say("JavaDB test dumped to $testfile");
    } else {
        say(" Test case contains mysql-specific constructs. Creating a JavaDB test case is not possible.");
    }

	return $transform_outcome;
}

1;
