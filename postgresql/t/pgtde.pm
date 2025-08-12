package PGTDE;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;

use File::Basename;
use File::Compare;
use Test::More;
use Time::HiRes qw(usleep);

# Expected .out filename of TAP testcase being executed. These are already part of repo under t/expected/*.
our $expected_filename_with_path;

# Result .out filename of TAP testcase being executed. Where needed, a new *.out will be created for each TAP test.
our $out_filename_with_path;

# Runtime output file that is used only for debugging purposes for comparison to PGSS, blocks and timings.
our $debug_out_filename_with_path;

my $expected_folder = "t/expected";
my $results_folder = "t/results";

sub psql
{
	my ($node, $dbname, $sql) = @_;

	my (undef, $stdout, $stderr) = $node->psql($dbname, $sql,
		extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);

	if ($stdout ne '')
	{
		append_to_result_file($stdout);
	}

	if ($stderr ne '')
	{
		append_to_result_file($stderr);
	}
}

# Copied from src/test/recovery/t/017_shm.pl
sub poll_start
{
	my ($node) = @_;

	my $max_attempts = 10 * $PostgreSQL::Test::Utils::timeout_default;
	my $attempts = 0;

	while ($attempts < $max_attempts)
	{
		$node->start(fail_ok => 1) && return 1;

		# Wait 0.1 second before retrying.
		usleep(100_000);

		# Clean up in case the start attempt just timed out or some such.
		$node->stop('fast', fail_ok => 1);

		$attempts++;
	}

	# Try one last time without fail_ok, which will BAIL_OUT unless it
	# succeeds.
	$node->start && return 1;
	return 0;
}

sub append_to_result_file
{
	my ($str) = @_;

	append_to_file($out_filename_with_path, $str . "\n");
}

sub append_to_debug_file
{
	my ($str) = @_;

	append_to_file($debug_out_filename_with_path, $str . "\n");
}

sub setup_files_dir
{
	my ($test_filename) = @_;

	unless (-d $results_folder)
	{
		mkdir $results_folder
		  or die "Can't create folder $results_folder: $!\n";
	}

	my ($test_name) = $test_filename =~ /([^.]*)/;

	$expected_filename_with_path = "${expected_folder}/${test_name}.out";
	$out_filename_with_path = "${results_folder}/${test_name}.out";
	$debug_out_filename_with_path =
	  "${results_folder}/${test_name}.out.debug";

	if (-f $out_filename_with_path)
	{
		unlink($out_filename_with_path)
		  or die
		  "Can't delete already existing $out_filename_with_path: $!\n";
	}
}

sub compare_results
{
	return compare($expected_filename_with_path, $out_filename_with_path);
}

sub backup
{
	my ($node, $backup_name, %params) = @_;
	my $backup_dir = $node->backup_dir . '/' . $backup_name;

	mkdir $backup_dir or die "mkdir($backup_dir) failed: $!";

	my $pg_tde_dir = $node->data_dir . '/pg_tde';
	if (-d $pg_tde_dir) {
		PostgreSQL::Test::RecursiveCopy::copypath($pg_tde_dir, $backup_dir . '/pg_tde');
	}
	else {
		note "Skipping pg_tde directory backup ?~@~T not present in data directory";
	}

	$node->backup($backup_name, %params);
}

sub setup_pg_tde_node {
    my ($node, $test_name) = @_;

    # Default test_name from script name if not provided
    $test_name ||= basename($0, '.pl');
    # Add process ID to ensure parallel safety
    my $pid = $$;
    # Build unique keyring file paths in /tmp
    my $global_keyring = File::Spec->catfile('/tmp', "global_keyring_${test_name}_${pid}.file");
    my $local_keyring  = File::Spec->catfile('/tmp', "local_keyring_${test_name}_${pid}.file");

    # Basic pg_tde settings
    $node->append_conf('postgresql.conf',
        "shared_preload_libraries = 'pg_tde'");
    $node->append_conf('postgresql.conf',
        "default_table_access_method = 'tde_heap'");

    $node->start;

    # Remove any existing keyring files for this test
    unlink($global_keyring_file);
    unlink($local_keyring_file);

    # Create and enable pg_tde extension
    $node->safe_psql('postgres',
        'CREATE EXTENSION IF NOT EXISTS pg_tde;');

	# Create global key provider and set server key
    $node->safe_psql('postgres',
        "SELECT pg_tde_add_global_key_provider_file(
            'global_key_provider', '$global_keyring_file');");

    $node->safe_psql('postgres',
        "SELECT pg_tde_create_key_using_global_key_provider(
            'global_test_key_time', 'global_key_provider');");

    $node->safe_psql('postgres',
        "SELECT pg_tde_set_server_key_using_global_key_provider(
            'global_test_key_time', 'global_key_provider');");

	# Create local key provider and set database key
    $node->safe_psql('postgres',
        "SELECT pg_tde_add_database_key_provider_file(
            'local_key_provider', '$local_keyring_file');");

    $node->safe_psql('postgres',
        "SELECT pg_tde_create_key_using_database_key_provider(
            'local_test_key_time', 'local_key_provider');");

    $node->safe_psql('postgres',
        "SELECT pg_tde_set_key_using_database_key_provider(
            'local_test_key_time', 'local_key_provider');");

    # WAL encryption setting
    my $WAL_ENCRYPTION = $ENV{WAL_ENCRYPTION} // 'on';
    $node->append_conf(
        'postgresql.conf',
        ($WAL_ENCRYPTION eq 'off')
            ? "pg_tde.wal_encrypt = off\n"
            : "pg_tde.wal_encrypt = on\n"
    );
}

1;
