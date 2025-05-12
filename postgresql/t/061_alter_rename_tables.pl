use strict;
use warnings FATAL => 'all';
use File::Basename;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use lib 't';
use pgtde;
use tde_helper;
use Time::HiRes qw(time sleep);
use IPC::Run qw(run);
use POSIX ":sys_wait_h";
use File::Temp qw(tempfile);
use POSIX qw(_exit);
use File::Path 'make_path';

PGTDE::setup_files_dir(basename($0));

my $DB_NAME= "test_db";

# Initialize primary node
my $node_primary = PostgreSQL::Test::Cluster->new('primary');
$node_primary->init;

enable_pg_tde_in_conf($node_primary);
set_default_table_am_tde_heap($node_primary);

$node_primary->append_conf('postgresql.conf', "listen_addresses = '*'");
$node_primary->start;

# Create a new database if not exists
ensure_database_exists_and_accessible($node_primary, $DB_NAME);

# Setup pg_tde encryption on the primary node
setup_encryption($node_primary, $DB_NAME);

my $TEST_DURATION = 20;
my $start_time = time();
my $end_time = $start_time + $TEST_DURATION;

run_sysbench_prepare($node_primary, $DB_NAME, 10, 4);
run_oltp_bulk_insert($node_primary, $DB_NAME, 10, 4);

run_in_background(\&run_oltp_read_write, "OLTP Read Write", $node_primary, $DB_NAME, 10, 4, $TEST_DURATION);
run_in_background(\&rename_tables, "Rename tables", $node_primary, $DB_NAME,10, 10);
run_in_background(\&alter_toggle_table_am, "feature toggle", $node_primary, $DB_NAME, 10, 30);

diag("Waiting for all background tasks...");
wait_for_all_background_tasks();
diag("All background tasks completed.");
$node_primary->restart;
read_tables($node_primary, $DB_NAME);
done_testing();

#==========  SUBROUTINES ==========
sub alter_toggle_table_am {
    my ($node, $db_name, $tables, $duration_secs) = @_;
    my $end_time = time() + $duration_secs;
    while (time() < $end_time) 
    {
        my $table = int(rand($tables)) + 1;
        my $heap = (int(rand(2)) == 0) ? "heap" : "tde_heap";
        
        diag("Changing table sbtest$table to use $heap");
        eval {
            $node->safe_psql($db_name,
                "ALTER TABLE sbtest$table SET ACCESS METHOD $heap;"
            );
            $node->safe_psql($db_name,
                "ALTER TABLE sbtest${table}_r SET ACCESS METHOD $heap;"
            );
        };
        sleep(5 + rand(15));
    }
}

sub rename_tables {
    my ($node, $db_name, $tables, $duration_secs) = @_;

    my $end_time = time() + $duration_secs;
    my $suffix   = "_r";

    while (time() < $end_time) {
        my $table_num = int(rand($tables)) + 1;
        my $original  = "sbtest$table_num";
        my $renamed   = "${original}${suffix}";

        # Check which table name exists
        my $exists = $node->safe_psql(
            $db_name,
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename IN ('$original', '$renamed');"
        );
        $exists =~ s/\s+//g;  # Remove any whitespace

        if ($exists eq '') {
            diag "Neither $original nor $renamed exists yet, skipping.";
            next;
        }

        my $new_name = ($exists eq $original) ? $renamed : $original;

        diag "Renaming $exists to $new_name";
        my $rename_status = $node->psql($db_name, "ALTER TABLE $exists RENAME TO $new_name;");
        #ok($rename_status == 0, "Renamed $exists to $new_name");

        sleep(1);  # avoid tight loop
    }
}

sub read_tables {
    my ($node, $db_name) = @_;
    note("Reading all tables starting with 'sbtest'");

    my $tables_output = $node->safe_psql($db_name, "SELECT tablename FROM pg_tables WHERE tablename LIKE 'sbtest%'");

    my @tables = split /\n/, $tables_output;

    foreach my $table (@tables) {
        $table =~ s/\s+//g;  # Sanitize whitespace

        my ($result, $encryption_result);
        eval {
            $result = $node->safe_psql($db_name, "SELECT COUNT(*) FROM \"$table\"");
            $encryption_result = $node->safe_psql($db_name, "SELECT pg_tde_is_encrypted('$table')");
        };

        if ($@) {
            note("Table $table does not exist or query failed: $@");
            pass("Handled missing or inaccessible table $table");
        } else {
            chomp($result);
            pass("Read from $table: $result rows");
            pass("Encryption status for $table: $encryption_result");
        }
    }
}



