package GenTest::Utilites;

use strict;
use GenTest;
use GenTest::Executor;
use GenTest::Executor::MySQL;
use GenTest::Executor::Postgres;
use GenTest::Executor::JavaDB;

sub newFromDSN
{
    my ($self,$dsn) = @_;
    
    if ($dsn =~ m/^dbi:mysql:/) {
        return GenTest::Executor::MySQL->new(dsn => $dsn);
    } elsif ($dsn =~ m/^dbi:JDBC:.*url=jdbc:derby:/) {
        return GenTest::Executor::JavaDB->new(dsn => $dsn);
    } elsif ($dsn =~ m/^dbi:Pg:/) {
        return GenTest::Executor::Postgres->new(dsn => $dsn);
    } else {
        say("Unsupported dsn: $dsn");
        exit(Gentest::Executor->STATUS_ENVIRONMENT_FAILURE);
    }
}

1;
