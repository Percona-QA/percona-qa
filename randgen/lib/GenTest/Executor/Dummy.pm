package GenTest::Executor::Dummy;

require Exporter;

@ISA = qw(GenTest::Executor);

use strict;
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Executor;

use Data::Dumper;


sub init {
	my $executor = shift;

    ## Just to have somthing that is not undefined
	$executor->setDbh($executor); 

	return STATUS_OK;
}

sub execute {
	my ($executor, $query, $silent) = @_;

    if ($ENV{RQG_DEBUG} or $executor->dsn() =~ m/print/) {
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
