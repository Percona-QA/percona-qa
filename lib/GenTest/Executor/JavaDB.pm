package GenTest::Executor::JavaDB;

require Exporter;

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
use GenTest::Translator::MysqlDML2javadb;
use GenTest::Translator::Mysqldump2javadb;
use Time::HiRes;

my %caches;

my %reported_errors;

my %acceptedErrors = (
    "42Y55" => 1 # DROP TABLE on non-existing table is accepted since
                 # tests rely on non-standard MySQL DROP IF EXISTS;
    );

sub init {
    
    my $self = shift;

    ## The jdbc URL may contain both = and ;. These characters have to
    ## be encoded in order to pass unharmed through DBI. We assume
    ## here, that url=.... is the last part of the dsn, and encode
    ## everything after url=

    my ($dsn_part1,$dsn_part2) = split(/url=/,$self->dsn());

    $dsn_part2 =~ s/([=;])/uc sprintf("%%%02x",ord($1))/eg;

    my $dbh = DBI->connect($dsn_part1."url=".$dsn_part2, undef, undef, 
                           {
                               PrintError => 0,
                               RaiseError => 0,
                               AutoCommit => 1
                           });
    
    if (not defined $dbh) {
        say("connect() to dsn ".$self->dsn()." failed: ".$DBI::errstr);
        return STATUS_ENVIRONMENT_FAILURE;
    }
    
    $self->setDbh($dbh);
    
    return STATUS_OK;
}

sub execute {
    my ($self, $query, $silent) = @_;

    my $dbh = $self->dbh();

    return GenTest::Result->new( 
        query => $query, 
        status => STATUS_UNKNOWN_ERROR ) 
        if not defined $dbh;

    $query = $self->preprocess($query);

    ## This may be generalized into a translator which is a pipe

    my @pipe = (GenTest::Translator::Mysqldump2javadb->new(),
                GenTest::Translator::MysqlDML2javadb->new());

    foreach my $p (@pipe) {
        $query = $p->translate($query);
        return GenTest::Result->new( 
            query => $query, 
            status => STATUS_WONT_HANDLE ) 
            if not $query;

    }

    if (!$dbh->ping()) {
        ## Reinit if connection is dead
        say("JavaDB connection is dead. Reconnect");
        $self->init();
        $dbh=$self->dbh();
    }

    # Autocommit ?

    my $db = $self->getName()." ".$self->version();

    my $start_time = Time::HiRes::time();


    my $sth = $dbh->prepare($query);

    if (defined $dbh->err()) {
        ## Error on prepare. Check for the ones we accept (E.g. DROP
        ## TABLE on non-existing table)
        if (not defined $acceptedErrors{$dbh->state()}) {
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
    }

    my $affected_rows = $sth->execute();
    
    my $end_time = Time::HiRes::time();
    
    my $err = $sth->err();
    my $result;

    if (defined $err) {         
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
            $self->normalize($row);
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


## Normalizing is in this case the process of making the rsult look
## like it came from MySQL
sub normalize {
    my ($self, $row) = @_;

    foreach my $e (@$row) {
        ## Remove .0 fractions from timestamps
        $e =~ s/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.0+$/\1/;
    }
}


sub DESTROY {
	my ($self) = @_;
	if (rqg_debug()) {
		say("Statistics for Executor ".$self->dsn()); 
		use Data::Dumper;
		$Data::Dumper::Sortkeys = 1;
		say("Rows returned:");
		print Dumper $self->[EXECUTOR_ROW_COUNTS];
		say("Explain items:");
		print Dumper $self->[EXECUTOR_EXPLAIN_COUNTS];
		say("Errors:");
		print Dumper $self->[EXECUTOR_ERROR_COUNTS];
		say("Rare EXPLAIN items:");
		print Dumper $self->[EXECUTOR_EXPLAIN_QUERIES];
	}
	$self->dbh()->disconnect();
}

sub version {
	my ($self) = @_;
	return "Version N/A"; # Not implemented in DBD::JDBC
}


sub tables {
	my ($executor, $database) = @_;

	return [] if not defined $executor->dbh();

	my $cache_key = join('-', ('tables', $database));
	my $dbname = defined $database ? "$database" : "APP";
	my $query = 
        "SELECT t.tablename FROM ". 
        " sys.systables AS t INNER JOIN sys.sysschemas AS s ".
        " ON t.schemaid = s.schemaid ".
        " WHERE s.schemaname = '$dbname' ".
        " AND t.tablename != 'DUMMY'";
	$caches{$cache_key} = $executor->dbh()->selectcol_arrayref($query) if not exists $caches{$cache_key};
	return $caches{$cache_key};
}

sub fields {
    my ($executor, $table, $database) = @_;
	
    return [] if not defined $executor->dbh();
    
    my $cache_key = join('-', ('fields', $table, $database));
    my $dbname = defined $database ? "$database" : "APP";
    $table = $executor->tables($database)->[0] if not defined $table;
    
    my $query = 
        "SELECT c.columnname FROM ".
        "sys.systables AS t INNER JOIN sys.sysschemas AS s ".
        "ON t.schemaid = s.schemaid INNER JOIN sys.syscolumns as c ".
        "ON t.tableid = c.referenceid ".
        " where s.schemaname='$dbname' and t.tablename = '$table'";
    
    
    $caches{$cache_key} = $executor->dbh()->selectcol_arrayref($query) if not exists $caches{$cache_key};
    
    return $caches{$cache_key};
}

sub fieldsIndexed {
    my ($executor, $table, $database) = @_;

    return [] if not defined $executor->dbh();

    my $cache_key = join('-', ('fields_indexed', $table, $database));
    my $dbname = defined $database ? "$database" : "APP";
    $table = $executor->tables($database)->[0] if not defined $table;
	
    my $query = 
	"SELECT columnname FROM ".
	"sys.syskeys AS keys ".
	"INNER JOIN sys.sysconglomerates AS cong ON keys.conglomerateid = cong.conglomerateid ".
	"INNER JOIN sys.systables AS tab ON cong.tableid = tab.tableid ".
	"INNER JOIN sys.sysschemas AS sch ON tab.schemaid = sch.schemaid ".
	"INNER JOIN sys.syscolumns AS col ON col.referenceid = tab.tableid ".
	"WHERE cong.isindex AND tablename = '$table' ".
	"AND schemaname = '$dbname'";
    
    
    $caches{$cache_key} = $executor->dbh()->selectcol_arrayref($query) 
	if not exists $caches{$cache_key};
    
    return $caches{$cache_key};
}

sub fieldsNoPK {
    ## FIXME dont know how yet
    my ($executor, $table, $database) = @_;
    return $executor->fields($table, $database);
}


1;
