package GenTest::Simplifier::Mysqltest;

require Exporter;
use GenTest;
@ISA = qw(GenTest);

use strict;
use lib 'lib';
use GenTest;
use GenTest::Constants;

my @csv_modules = (
	'Text::CSV',
	'Text::CSV_XS',
	'Text::CSV_PP'
);

use constant SIMPLIFIER_ORACLE          => 0;
use constant SIMPLIFIER_FILTER		=> 1;
use constant SIMPLIFIER_USE_CONNECTIONS	=> 2;

1;

sub new {
        my $class = shift;

	my $simplifier = $class->SUPER::new({
		oracle		=> SIMPLIFIER_ORACLE,
		filter		=> SIMPLIFIER_FILTER,
		use_connections => SIMPLIFIER_USE_CONNECTIONS
	}, @_);

	return $simplifier;
}

sub simplify {
	my ($simplifier, $initial_mysqltest) = @_;

	my @queries = split("\n", $initial_mysqltest);

	my $filtered_out = 0;

	foreach my $i (0..$#queries) {
		if ($queries[$i] =~ m{$simplifier->[SIMPLIFIER_FILTER]}sio) {
			$filtered_out++;
			splice @queries, $i, 1;
		}
	}

	say("Filtered $filtered_out queries out of ".($#queries+1));

	if (!$simplifier->oracle(join("\n", @queries)."\n")) {
		warn("Initial mysqltest failed oracle check.");
		return undef;
	}

	my $ddmin_outcome = $simplifier->ddmin(\@queries);
	my $final_mysqltest = join("\n", @$ddmin_outcome)."\n";

	if (!$simplifier->oracle($final_mysqltest)) {
		warn("Final mysqltest failed oracle check.");
		return undef;
	} else {
		return $final_mysqltest;
	}
}

sub simplifyFromCSV {
	my ($simplifier, $csv_file) = @_;

	my $csv;
	foreach my $csv_module (@csv_modules) {
	        eval ("require $csv_module");
		if (!$@) {
			$csv = $csv_module->new({ 'escape_char' => '\\' });
			say("Loaded CSV module $csv_module");
			last;
		}
	}

	die "Unable to load a CSV Perl module" if not defined $csv;

	my @mysqltest;
	
	open (CSV_HANDLE, "<", $csv_file) or die $!;
	my %connections;
	my $last_connection;
	while (<CSV_HANDLE>) {
		$_ =~ s{\\n}{ }sgio;
		if ($csv->parse($_)) {
			my @columns = $csv->fields();
			my $connection_id = $columns[2];
			my $connection_name = 'connection_'.$connection_id;
			my $command = $columns[4];
			my $query = $columns[5];

			if (($command eq 'Connect') && ($simplifier->[SIMPLIFIER_USE_CONNECTIONS])) {
				my ($username, $host, $database) = $query =~ m{(.*?)\@(.*?) on (.*)}sio;
				push @mysqltest, "--connect ($connection_name, localhost, $username, , $database)";
				$connections{$connection_name}++;
			} elsif (($command eq 'Quit') && ($simplifier->[SIMPLIFIER_USE_CONNECTIONS])) {
				push @mysqltest, "--disconnect $connection_name";
			} elsif ($command eq 'Query') {

				if (($last_connection ne $connection_name) && ($simplifier->[SIMPLIFIER_USE_CONNECTIONS])) {
					if (not exists $connections{$connection_name}) {
						push @mysqltest, "--connect ($connection_name, localhost, root, , test)";
		                                $connections{$connection_name}++;
					}

					push @mysqltest, "--connection $connection_name";
					$last_connection = $connection_name;
				}
			
				$query =~ s{\\n}{ }sgio;
				$query =~ s{\\\\}{\\}sgio;

				if ($query =~ m{;}){
					push @mysqltest, ("DELIMITER |;",$query.'|', "DELIMITER ;|");
				} else {
					push @mysqltest, $query.';';
				}
			}
	        } else {
			my $err = $csv->error_input;
			say ("Failed to parse line: $err");
		}
	}
	close CSV_HANDLE;

	say("Loaded ".($#mysqltest + 1)." lines from CSV");

	return $simplifier->simplify(join("\n", @mysqltest)."\n");
}

sub oracle {
        my ($simplifier, $mysqltest) = @_;

        my $oracle = $simplifier->[SIMPLIFIER_ORACLE];

	return $oracle->($mysqltest); 
}

#
# This is an implementation of the ddmin algorithm, as described in "Why Programs Fail" by Andreas Zeller
#

sub ddmin {
	my ($simplifier, $inputs) = @_;
	say("input_size: ".($#$inputs + 1));
	my $splits = 2;

	# We start from 1, as to preserve the top-most queries since they are usually vital
	my $starting_subset = 1;

	outer: while (2 <= @$inputs) {
		my @subsets = subsets($inputs, $splits);
		say("inputs: ".($#$inputs + 1)."; splits: $splits; subsets: ".($#subsets + 1));

		my $some_complement_is_failing = 0;
		foreach my $subset_id ($starting_subset..$#subsets) {
			my $subset = $subsets[$subset_id];
			my $complement = listMinus($inputs, $subset);
			say("subset_id: $subset_id; subset_size: ".($#$subset + 1)."; complement_size: ".($#$complement + 1));
#			say("subset: ".join('|',@$subset));
#			say("complement: ".join('|',@$complement));
			if ($simplifier->oracle(join("\n", @$complement)) == ORACLE_ISSUE_STILL_REPEATABLE) {
				$starting_subset = $subset_id; 	# At next iteration, continue from where we left off 
				$inputs = $complement;
				$splits-- if $splits > 2;
				$some_complement_is_failing = 1;
				next outer;
			}
		}

		if (!$some_complement_is_failing) {
			last if $splits == ($#$inputs + 1);
			$splits = $splits * 2 > $#$inputs + 1 ? $#$inputs + 1 : $splits * 2;
		}

		$starting_subset = 1;	# Reached EOF, start again from the top

	}

	return $inputs;
}

sub subsets {
	my ($list1, $subset_count) = @_;

	my $subset_size = int(($#$list1 + 1) / $subset_count);

	my @subsets;
	my $current_subset = 0;
	foreach my $element_id (0..$#$list1) {
		push @{$subsets[$current_subset]}, $list1->[$element_id];
		$current_subset++ if ($#{$subsets[$current_subset]} + 1) >= $subset_size && ($current_subset + 1) < $subset_count;
	}

	return @subsets;
}

sub listMinus {
	my ($list1, $list2) = @_;

	my $list1_string = join("\n", @$list1);
	my $list2_string = join("\n", @$list2);
	
	my $list3_string = $list1_string;
	my $list2_pos = index($list1_string, $list2_string);
	if ($list2_pos > -1) {
		substr($list3_string, $list2_pos, length($list2_string), '');
		$list3_string =~ s{^\n}{}sgio;
		$list3_string =~ s{\n$}{}sgio;
		my @list3 = split (m{\n+}, $list3_string);
		return \@list3;
	} else {
		die "list2 is not a subset of list1";
	}
}	

1;
