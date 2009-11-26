package GenTest::Executor::Dummy;

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
use GenTest::Translator::MysqlDML2pgsql;
use GenTest::Translator::Mysqldump2pgsql;


use Data::Dumper;


sub init {
	my $executor = shift;

    ## Just to have somthing that is not undefined
	$executor->setDbh($executor); 

	return STATUS_OK;
}

sub execute {
	my ($self, $query, $silent) = @_;

    $query = $self->preprocess($query);

    ## This may be generalized into a translator which is a pipe

    my @pipe;
    if ($self->dsn() =~ m/javadb/) {
        @pipe = (GenTest::Translator::Mysqldump2javadb->new(),
                 GenTest::Translator::MysqlDML2javadb->new());

    } elsif ($self->dsn() =~ m/postgres/) {

        @pipe = (GenTest::Translator::Mysqldump2pgsql->new(),
                 GenTest::Translator::MysqlDML2pgsql->new());

    }
    foreach my $p (@pipe) {
        $query = $p->translate($query);
        return GenTest::Result->new( 
            query => $query, 
            status => STATUS_WONT_HANDLE ) 
            if not $query;
        
    }

    if ($ENV{RQG_DEBUG} or $self->dsn() =~ m/print/) {
        print "Executing $query\n";
    }

	return new GenTest::Result(query => $query,
                               status => STATUS_OK);
}


sub version {
	my ($self) = @_;
	return "Version N/A"; # Not implemented in DBD::JDBC
}

sub tables {
	my ($self, $database) = @_;
    
    my @t = ("MYTABLE");

    return \@t;
}

sub fields {
	my ($self, $database) = @_;
    
    my @f = ("MYFIELD");

    return \@f;
}

1;
