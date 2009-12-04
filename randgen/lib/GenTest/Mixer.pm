package GenTest::Mixer;

require Exporter;
@ISA = qw(GenTest);

use strict;
use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;

use constant MIXER_GENERATOR	=> 0;
use constant MIXER_EXECUTORS	=> 1;
use constant MIXER_VALIDATORS	=> 2;
use constant MIXER_FILTERS	=> 3;

1;

sub new {
	my $class = shift;

	my $mixer = $class->SUPER::new({
		'generator'	=> MIXER_GENERATOR,
		'executors'	=> MIXER_EXECUTORS,
		'validators'	=> MIXER_VALIDATORS,
		'filters'	=> MIXER_FILTERS
	}, @_);

	foreach my $executor (@{$mixer->executors()}) {
		my $init_result = $executor->init();
		return undef if $init_result > STATUS_OK;
        $executor->cacheMetaData();
	}

	my @validators = @{$mixer->validators()};
	my %validators;

	# If a Validator was specified by name, load the class and create an object.

	foreach my $i (0..$#validators) {
		my $validator = $validators[$i];
		if (ref($validator) eq '') {
			$validator = "GenTest::Validator::".$validator;
#			say("Loading Validator $validator.");
			eval "use $validator" or print $@;
			$validators[$i] = $validator->new();
		}
		$validators{ref($validators[$i])}++;
	}

	# Query every object for its prerequisies. If one is not loaded, load it and place it
	# in front of the Validators array.

	my @prerequisites;
	foreach my $validator (@validators) {
		my $prerequisites = $validator->prerequsites();
		next if not defined $prerequisites;
		foreach my $prerequisite (@$prerequisites) {
			next if exists $validators{$prerequisite};
			$prerequisite = "GenTest::Validator::".$prerequisite;
#			say("Loading Prerequisite $prerequisite, required by $validator.");
			eval "use $prerequisite" or print $@;
			push @prerequisites, $prerequisite->new();
		}
	}

	my @validators = (@prerequisites, @validators);
	$mixer->setValidators(\@validators);

	foreach my $validator (@validators) {
		return undef if not defined $validator->init($mixer->executors());
	}

	return $mixer;
}

sub next {
	my $mixer = shift;

	my $executors = $mixer->executors();
	my $filters = $mixer->filters();

	my $queries = $mixer->generator()->next($executors);
	if (not defined $queries) {
		say("Internal grammar problem. Terminating.");
		return STATUS_ENVIRONMENT_FAILURE;
	} elsif ($queries->[0] eq '') {
#		say("Your grammar generated an empty query.");
#		return STATUS_ENVIRONMENT_FAILURE;
	}

	my $max_status = STATUS_OK;

	query: foreach my $query (@$queries) {
		next if $query =~ m{^\s*$}o;

		if (defined $filters) {
			foreach my $filter (@$filters) {
				my $filter_result = $filter->filter($query);
				next query if $filter_result == STATUS_SKIP;
			}
		}

		my @execution_results;
		foreach my $executor (@$executors) {
			my $execution_result = $executor->execute($query);
			$max_status = $execution_result->status() if $execution_result->status() > $max_status;
			push @execution_results, $execution_result;
			
			# If one server has crashed, do not send the query to the second one in order to preserve consistency
			if ($execution_result->status() == STATUS_SERVER_CRASHED) {
				say("Server crash reported at dsn ".$executor->dsn());
				last;
			}
		}
		
		foreach my $validator (@{$mixer->validators()}) {
			my $validation_result = $validator->validate($executors, \@execution_results);
			$max_status = $validation_result if ($validation_result != STATUS_WONT_HANDLE) && ($validation_result > $max_status);
		}
	}

	return $max_status;
}

sub generator {
	return $_[0]->[MIXER_GENERATOR];
}

sub executors {
	return $_[0]->[MIXER_EXECUTORS];
}

sub validators {
	return $_[0]->[MIXER_VALIDATORS];
}

sub filters {
	return $_[0]->[MIXER_FILTERS];
}

sub setValidators {
	$_[0]->[MIXER_VALIDATORS] = $_[1];
}

1;
