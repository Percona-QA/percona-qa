package GenTest::Executor::Postgres;

@ISA = qw(GenTest::Executor);

use strict;
use DBI;

use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Executor;
use GenTest::Translator;
use GenTest::Translator::MysqlDML2ANSI;
use GenTest::Translator::Mysqldump2ANSI;
use GenTest::Translator::MysqlDML2pgsql;
use GenTest::Translator::Mysqldump2pgsql;
use Time::HiRes;
use Data::Dumper;

sub init {
	my $self = shift;

	my $dbh =  DBI->connect($self->dsn(), undef, undef,
                            {
                                PrintError => 0,
                                RaiseError => 0,
                                AutoCommit => 1}
        );

    if (not defined $dbh) {
        say("connect() to dsn ".$self->dsn()." failed: ".$DBI::errstr);
        return STATUS_ENVIRONMENT_FAILURE;
    }
    
	$self->setDbh($dbh);	

    return STATUS_OK;
}

my %caches;

my %acceptedErrors = (
    "42P01" => 1 # DROP TABLE on non-existing table is accepted since
                 # tests rely on non-standard MySQL DROP IF EXISTS;
    );

sub execute {
    my ($self, $query, $silent) = @_;

    my $dbh = $self->dbh();

    return GenTest::Result->new( 
        query => $query, 
        status => STATUS_UNKNOWN_ERROR ) 
        if not defined $dbh;
    
    $query = $self->preprocess($query);
    
    ## This may be generalized into a translator which is a pipe

    my @pipe = (GenTest::Translator::Mysqldump2pgsql->new(),
                GenTest::Translator::MysqlDML2pgsql->new());

    foreach my $p (@pipe) {
        $query = $p->translate($query);
        return GenTest::Result->new( 
            query => $query, 
            status => STATUS_WONT_HANDLE ) 
            if not $query;
    }

    # Autocommit ?

    my $db = $self->getName()." ".$self->version();

    my $start_time = Time::HiRes::time();

    my $sth = $dbh->prepare($query);

    if (defined $dbh->err()) {
        my $errstr = $db.":".$dbh->state().":".$dbh->errstr();
        say($errstr . "($query)") if !$silent;
        $self->[EXECUTOR_ERROR_COUNTS]->{$errstr}++ if rqg_debug() && !$silent;
        return GenTest::Result->new(
            query       => $query,
            status      => $self->findStatus($dbh->state()),
            err         => $dbh->err(),
            errstr      => $dbh->errstr(),
            sqlstate    => $dbh->state(),
            start_time  => $start_time,
            end_time    => Time::HiRes::time()
            );
    }


    my $affected_rows = $sth->execute();

    
    my $end_time = Time::HiRes::time();
    
    my $err = $sth->err();
    my $result;
    
    if (defined $err) {         
        if (not defined $acceptedErrors{$dbh->state()}) {
            ## Error on EXECUTE
            my $errstr = $db.":".$dbh->state().":".$dbh->errstr();
            say($errstr . "($query)") if !$silent;
            $self->[EXECUTOR_ERROR_COUNTS]->{$errstr}++ if rqg_debug() && !$silent;
            return GenTest::Result->new(
                query       => $query,
                status      => $self->findStatus($dbh->state()),
                err         => $dbh->err(),
                errstr      => $dbh->errstr(),
                sqlstate    => $dbh->state(),
                start_time  => $start_time,
                end_time    => $end_time
                );
        } else {
            ## E.g. DROP on non-existing table
            return GenTest::Result->new(
                query       => $query,
                status      => STATUS_OK,
                affected_rows => 0,
                start_time  => $start_time,
                end_time    => Time::HiRes::time()
                );
        }

    } elsif ((not defined $sth->{NUM_OF_FIELDS}) || ($sth->{NUM_OF_FIELDS} == 0)) {
        ## DDL/UPDATE/INSERT/DROP/DELETE
        $result = GenTest::Result->new(
            query       => $query,
            status      => STATUS_OK,
            affected_rows   => $affected_rows,
            start_time  => $start_time,
            end_time    => $end_time
            );
        $self->[EXECUTOR_ERROR_COUNTS]->{'(no error)'}++ if rqg_debug() && !$silent;
    } else {
        ## Query
        
        # We do not use fetchall_arrayref() due to a memory leak
        # We also copy the row explicitly into a fresh array
        # otherwise the entire @data array ends up referencing row #1 only
        my @data;
        while (my $row = $sth->fetchrow_arrayref()) {
            my @row = @$row;
            push @data, \@row;
        }   
        
        $result = GenTest::Result->new(
            query       => $query,
            status      => STATUS_OK,
            affected_rows   => $affected_rows,
            data        => \@data,
            start_time  => $start_time,
            end_time    => $end_time
            );
        
        $self->[EXECUTOR_ERROR_COUNTS]->{'(no error)'}++ if rqg_debug() && !$silent;
    }

    $sth->finish();

    return $result;
}

sub findStatus {
    my ($self, $state) = @_;

    if ($state eq "22000") {
	return STATUS_SERVER_CRASHED;
    } else {
	return $self->SUPER::find_status(@_);
    }
}

sub version {
	my $self = shift;
	my $dbh = $self->dbh();
    return $dbh->get_info(18);
}

sub tables {
	my ($executor, $database) = @_;

	return [] if not defined $executor->dbh();

	my $cache_key = join('-', ('tables', $database));
	my $dbname = defined $database ? "$database" : "public";
	my $query = 
		"SELECT table_name FROM information_schema.tables ". 
		"WHERE table_schema = '$dbname' " .
		" AND table_name != 'dummy'";
	$caches{$cache_key} = $executor->dbh()->selectcol_arrayref($query) if not exists $caches{$cache_key};
	return $caches{$cache_key};
}

sub fields {
	my ($executor, $table, $database) = @_;
	
	return [] if not defined $executor->dbh();

	my $cache_key = join('-', ('fields', $table, $database));
	my $dbname = defined $database ? "$database" : "public";
	$table = $executor->tables($database)->[0] if not defined $table;
    
    my $query = 
        "SELECT column_name FROM information_schema.columns ".
        " WHERE table_schema = '$dbname' AND table_name = '$table'";

	$caches{$cache_key} = $executor->dbh()->selectcol_arrayref($query) if not exists $caches{$cache_key};

	return $caches{$cache_key};
}


1;
