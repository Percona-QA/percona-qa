#!/usr/bin/perl
use lib 'lib';
use lib "$ENV{RQG_HOME}/lib";
use strict;
use GenTest;

$| = 1;
my $ctrl_c = 0;

$SIG{INT} = sub { $ctrl_c = 1 };
$SIG{TERM} = sub { exit(0) };
$SIG{CHLD} = "IGNORE" if windows();

if (defined $ENV{RQG_HOME}) {
	$ENV{RQG_HOME} = windows() ? $ENV{RQG_HOME}.'\\' : $ENV{RQG_HOME}.'/';
}

use constant PROCESS_TYPE_PARENT	=> 0;
use constant PROCESS_TYPE_PERIODIC	=> 1;
use constant PROCESS_TYPE_CHILD		=> 2;

use POSIX;
use Getopt::Long;
use Time::HiRes;

use GenTest::Utilities;

use GenTest::XML::Report;
use GenTest::XML::Test;
use GenTest::XML::BuildInfo;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;
use GenTest::Generator::FromGrammar;
use GenTest::Executor;
use GenTest::Executor::MySQL;
use GenTest::Executor::JavaDB;
use GenTest::Utilities;
use GenTest::Mixer;
use GenTest::Reporter;
use GenTest::ReporterManager;
use GenTest::Filter::Regexp;

my @dsns;
$dsns[0] = my $default_dsn = 'dbi:mysql:host=127.0.0.1:port=9306:user=root:database=test';
my $threads = my $default_threads = 10;
my $queries = my $default_queries = 1000;
my $duration = my $default_duration = 3600;

my ($gendata, $engine, $help, $debug, $rpl_mode, $grammar_file, $validators, $reporters, $mask, $rows, $varchar_len, $xml_output, $views, $start_dirty, $filter);
my $seed = 1;

my @ARGV_saved = @ARGV;

my $opt_result = GetOptions(
	'dsn=s'	=> \$dsns[0],
	'dsn1=s' => \$dsns[0],
	'dsn2=s' => \$dsns[1],
	'dsn3=s' => \$dsns[2],
	'engine=s' => \$engine,
	'gendata:s' => \$gendata,
	'grammar=s' => \$grammar_file,
	'threads=i' => \$threads,
	'queries=s' => \$queries,
	'duration=s' => \$duration,
	'help' => \$help,
	'debug' => \$debug,
	'rpl_mode=s' => \$rpl_mode,
	'validators:s' => \$validators,
	'reporters:s' => \$reporters,
	'seed=s' => \$seed,
	'mask=i' => \$mask,
	'rows=i' => \$rows,
	'varchar-length=i' => \$varchar_len,
	'xml-output=s' => \$xml_output,
	'views'	=> \$views,
	'start-dirty' => \$start_dirty,
	'filter=s' => \$filter
);

if ($seed eq 'time') {
	$seed = time();
	say("Converting --seed=time to --seed=$seed");
}

$ENV{RQG_DEBUG} = 1 if $debug;

$queries =~ s{K}{000}so;
$queries =~ s{M}{000000}so;

help() if !$opt_result || $help || not defined $grammar_file;

say("Starting \n $0 \\ \n ".join(" \\ \n ", @ARGV_saved));

if ((defined $gendata) && (not defined $start_dirty)) {
	foreach my $dsn (@dsns) {
		next if $dsn eq '';
		my $gendata_result;
		if ($gendata eq '') {
			$gendata_result = system("perl $ENV{RQG_HOME}gendata-old.pl --dsn=\"$dsn\" ".
								(defined $views ? "--views " : "").
				(defined $engine ? "--engine=$engine" : "")
			);
		} else {
			$gendata_result = system("perl $ENV{RQG_HOME}gendata.pl --config=$gendata --dsn=\"$dsn\" ".
				(defined $engine ? "--engine=$engine" : "")." ".
				(defined $seed ? "--seed=$seed" : "")." ".
				(defined $rows ? "--rows=$rows" : "")." ".
				(defined $views ? "--views" : "")." ".
				(defined $varchar_len ? "--varchar-length=$varchar_len" : "")." ");
		}
		safe_exit ($gendata_result >> 8) if $gendata_result > 0;
	}
}

my $test_start = time();
my $test_end = $test_start + $duration;

my ($grammar, @executors, @reporters);

my $grammar = GenTest::Grammar->new(
	grammar_file => $grammar_file
);

exit(STATUS_ENVIRONMENT_FAILURE) if not defined $grammar;

foreach my $i (0..2) {
	next if $dsns[$i] eq '';
	push @executors, GenTest::Utilites->newFromDSN($dsns[$i]);
}

my $mysql_only = $executors[0]->type == DB_MYSQL;
$mysql_only = $mysql_only && $executors[1]->type == DB_MYSQL if $#executors > 0;


if (not defined $reporters) {
	if ($mysql_only) {
		@reporters = ('ErrorLog', 'Backtrace');
	}
} else {
	@reporters = split(',', $reporters);
}

say("Reporters: ".($#reporters > -1 ? join(', ', @reporters) : "(none)"));

my $reporter_manager = GenTest::ReporterManager->new();

if ($mysql_only) {
	foreach my $i (0..2) {
		next if $dsns[$i] eq '';
		foreach my $reporter (@reporters) {
			my $add_result = $reporter_manager->addReporter($reporter, {
				dsn			=> $dsns[$i],
				test_start	=> $test_start,
				test_end	=> $test_end,
				test_duration	=> $duration
															} );
			exit($add_result) if $add_result > STATUS_OK;
		}
	}
}

my @validators;

if (not defined $validators) {
	@validators = ('ErrorMessageCorruption') if $mysql_only;
    if ($dsns[2] ne '') {
        push @validators, 'ResultsetComparator3';
    } elsif ($dsns[1] ne '') {
        push @validators, 'ResultsetComparator';
    }
	push @validators, 'ReplicationSlaveStatus' if $rpl_mode ne '' && $mysql_only;
	push @validators, 'QueryProperties' if $grammar->hasProperties() && $mysql_only;
} else {
	@validators = split(',', $validators);
}

say("Validators: ".($#validators > -1 ? join(', ', @validators) : "(none)"));

my $filter_obj;

$filter_obj = GenTest::Filter::Regexp->new( file => $filter ) if defined $filter;

say("Starting $threads processes, $queries queries each, duration $duration seconds.");

my $buildinfo;
if (defined $xml_output) {
	$buildinfo = GenTest::XML::BuildInfo->new(
		dsns => \@dsns
		);
}

my $test = GenTest::XML::Test->new(
	id => Time::HiRes::time(),
	attributes => {
		engine => $engine,
		gendata => $gendata,
		grammar => $grammar_file,
		threads => $threads,
		queries => $queries,
		validators => join (',', @validators),
		reporters => join (',', @reporters),
		seed => $seed,
		mask => $mask,
		rows => $rows,
		'varchar-length' => $varchar_len
	}
);

my $report = GenTest::XML::Report->new(
	buildinfo => $buildinfo,
	tests => [ $test ]
);

my $process_type;
my %child_pids;
my $id = 1;

my $periodic_pid = fork();
if ($periodic_pid == 0) {
	Time::HiRes::sleep(($threads + 1) / 10);
	say("Started periodic reporting process...");
	$process_type = PROCESS_TYPE_PERIODIC;
	$id = 0;
} else {
	foreach my $i (1..$threads) {
		my $child_pid = fork();
		if ($child_pid == 0) { # This is a child 
			$process_type = PROCESS_TYPE_CHILD;
			last;
		} else {
			$child_pids{$child_pid} = 1;
			$process_type = PROCESS_TYPE_PARENT;
			$seed++;
			$id++;
			Time::HiRes::sleep(0.1);	# fork slowly for more predictability
			next;
		}
	}
}

if ($process_type == PROCESS_TYPE_PARENT) {
	# We are the parent process, wait for for all spawned processes to terminate
	my $children_died = 0;
	my $total_status = STATUS_OK;
	my $periodic_died = 0;
	while (1) {
		my $child_pid = wait();
		my $exit_status = $? > 0 ? ($? >> 8) : 0;

		$total_status = $exit_status if $exit_status > $total_status;

		if ($child_pid == $periodic_pid) {
			$periodic_died = 1;
			last;
		} else {
			$children_died++;
			delete $child_pids{$child_pid};
		}

		last if $exit_status >= STATUS_CRITICAL_FAILURE;
		last if $children_died == $threads;
		last if $child_pid == -1;
	}

	foreach my $child_pid (keys %child_pids) {
		say("Killing child process with pid $child_pid...");
		kill(15, $child_pid);
	}

	if ($periodic_died == 0) {
		# Wait for periodic process to return the status of its last execution
		Time::HiRes::sleep(1);
		say("Killing periodic reporting process with pid $periodic_pid...");
		kill(15, $periodic_pid);

		if (windows()) {
			# We use sleep() + non-blocking waitpid() due to a bug in ActiveState Perl
			Time::HiRes::sleep(1);
			waitpid($periodic_pid, &POSIX::WNOHANG() );
		} else {
			waitpid($periodic_pid, 0);
		}

		if ($? > -1 ) {
			my $periodic_status = $? > 0 ? $? >> 8 : 0;
			$total_status = $periodic_status if $periodic_status > $total_status;
		}
	}

	my @report_results;

	if ($total_status == STATUS_OK) {
		@report_results = $reporter_manager->report(REPORTER_TYPE_SUCCESS | REPORTER_TYPE_ALWAYS);
	} elsif (
		($total_status == STATUS_LENGTH_MISMATCH) ||
		($total_status == STATUS_CONTENT_MISMATCH)
	) {
		@report_results = $reporter_manager->report(REPORTER_TYPE_DATA);
	} elsif ($total_status == STATUS_SERVER_CRASHED) {
		say("Server crash reported, initiating post-crash analysis...");
		@report_results = $reporter_manager->report(REPORTER_TYPE_CRASH | REPORTER_TYPE_ALWAYS);
	} elsif ($total_status == STATUS_SERVER_DEADLOCKED) {
		say("Server deadlock reported, initiating analysis...");
		@report_results = $reporter_manager->report(REPORTER_TYPE_DEADLOCK | REPORTER_TYPE_ALWAYS);
	} elsif ($total_status == STATUS_SERVER_KILLED) {
		@report_results = $reporter_manager->report(REPORTER_TYPE_SERVER_KILLED | REPORTER_TYPE_ALWAYS);
	} else {
		@report_results = $reporter_manager->report(REPORTER_TYPE_ALWAYS);
	}

	my $report_status = shift @report_results;
	$total_status = $report_status if $report_status > $total_status;
	$total_status = STATUS_OK if $total_status == STATUS_SERVER_KILLED;

	foreach my $incident (@report_results) {
		$test->addIncident($incident);
	}

	$test->end($total_status == STATUS_OK ? "pass" : "fail");

	if (defined $xml_output) {
		open (XML , ">$xml_output") or say("Unable to open $xml_output: $!");
		print XML $report->xml();
		close XML;
	}

	if ($total_status == STATUS_OK) {
		say("Test completed successfully.");
		safe_exit(0);
	} else {
		say("Test completed with failure status $total_status.");
		safe_exit($total_status);
	}
} elsif ($process_type == PROCESS_TYPE_PERIODIC) {
	while (1) {
		my $reporter_status = $reporter_manager->monitor(REPORTER_TYPE_PERIODIC);
		exit($reporter_status) if $reporter_status > STATUS_CRITICAL_FAILURE;
		sleep(10);
	}
} elsif ($process_type == PROCESS_TYPE_CHILD) {
	# We are a child process, execute the desired queries and terminate

	my $generator = GenTest::Generator::FromGrammar->new(
		grammar => $grammar,
		varchar_length => $varchar_len,
		seed => $seed,
		thread_id => $id,
		mask => $mask
	);

	exit (STATUS_ENVIRONMENT_FAILURE) if not defined $generator;

	my $mixer = GenTest::Mixer->new(
		generator => $generator,
		executors => \@executors,
		validators => \@validators,
		filters => defined $filter_obj ? [ $filter_obj ] : undef
	);

	exit (STATUS_ENVIRONMENT_FAILURE) if not defined $mixer;

	my $max_result;

	foreach my $i (1..$queries) {
		my $result = $mixer->next();
		exit($result) if $result > STATUS_CRITICAL_FAILURE;
		$max_result = $result if $result > $max_result && $result > STATUS_TEST_FAILURE;
		last if $result == STATUS_EOF;
		last if $ctrl_c == 1;
		last if time() > $test_end;
	}

	if ($max_result > 0) {
		say("Child process completed with error code $max_result.");
		exit($max_result);
	} else {
		say("Child process completed successfully.");
		exit(0);
	}

} else {
	die ("Unknown process type $process_type");
}

sub help {

	print <<EOF

		$0 - Testing via random query generation. Options:

		--dsn			: MySQL DBI resource to connect to (default $default_dsn)
	--gendata	: Execute gendata.pl in order to populate tables with sample data (default NO)
		--engine		: Table engine to use when creating tables with gendata (default: no ENGINE for CREATE TABLE)
	--threads	: Number of threads to spawn (default $default_threads)
	--queries	: Numer of queries to execute per thread (default $default_queries);
		--duration		: Duration of the test in seconds (default $default_duration seconds);
	--grammar	: Grammar file to use for generating the queries (REQUIRED);
		--help			: This help message
	--debug		: Provide debug output
EOF
	;
	safe_exit(1);
}
