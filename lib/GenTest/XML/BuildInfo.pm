package GenTest::XML::BuildInfo;

require Exporter;
@ISA = qw(GenTest);

use strict;
use GenTest;
use DBI;

use constant BUILDINFO_DSNS     => 0;
use constant BUILDINFO_SERVERS  => 1;

use constant BUILDINFO_SERVER_VERSION   => 0;
use constant BUILDINFO_SERVER_PACKAGE   => 1;
use constant BUILDINFO_SERVER_BIT       => 2;
use constant BUILDINFO_SERVER_PATH      => 3;
use constant BUILDINFO_SERVER_VARIABLES => 4;

sub new {
    my $class = shift;

    my $buildinfo = $class->SUPER::new({
        dsns    => BUILDINFO_DSNS
    }, @_);

    $buildinfo->[BUILDINFO_SERVERS] = [];

    foreach my $id (0..$#{$buildinfo->[BUILDINFO_DSNS]})
    {
        my $dsn = $buildinfo->[BUILDINFO_DSNS]->[$id];
        next if $dsn eq '';
        my $dbh = DBI->connect($dsn);

        my $server;

        $server->[BUILDINFO_SERVER_VERSION] = $dbh->selectrow_array('SELECT @@version');
        $server->[BUILDINFO_SERVER_PACKAGE] = $dbh->selectrow_array('SELECT @@version_comment');
        $server->[BUILDINFO_SERVER_BIT] = $dbh->selectrow_array('SELECT @@version_compile_machine');
        $server->[BUILDINFO_SERVER_PATH] = $dbh->selectrow_array('SELECT @@basedir');
        $server->[BUILDINFO_SERVER_VARIABLES] = [];

        my $sth = $dbh->prepare("SHOW VARIABLES");
        $sth->execute();
        while (my ($name, $value) = $sth->fetchrow_array()) {
            push @{$server->[BUILDINFO_SERVER_VARIABLES]}, [ $name , $value ];
        }
        $sth->finish();

        $dbh->disconnect();

        $buildinfo->[BUILDINFO_SERVERS]->[$id] = $server;
    }

    return $buildinfo;
}

sub xml {
    require XML::Writer;

    my $buildinfo = shift;
    my $buildinfo_xml;

    my $writer = XML::Writer->new(
        OUTPUT      => \$buildinfo_xml,
    );

    $writer->startTag('product');
    $writer->dataElement('name','mysql');
    $writer->startTag('builds');

    foreach my $id (0..$#{$buildinfo->[BUILDINFO_DSNS]})
    {
        my $server = $buildinfo->[BUILDINFO_SERVERS]->[$id];
        next if not defined $server;

        $writer->startTag('build', id => $id);
        $writer->dataElement('version', $server->[BUILDINFO_SERVER_VERSION]);
        $writer->dataElement('package', $server->[BUILDINFO_SERVER_PACKAGE]);
        $writer->dataElement('bit', $server->[BUILDINFO_SERVER_BIT]);
        $writer->dataElement('path', $server->[BUILDINFO_SERVER_PATH]);
        # <compile_options>
        $writer->endTag('build');
    }


    $writer->endTag('builds');

    $writer->startTag('binaries');

    foreach my $id (0..$#{$buildinfo->[BUILDINFO_DSNS]})
    {
        my $server = $buildinfo->[BUILDINFO_SERVERS]->[$id];
        next if not defined $server;

        $writer->startTag('binary');
        $writer->dataElement('name', 'mysqld');
        $writer->startTag('commandline_options');

        foreach my $option (@{$server->[BUILDINFO_SERVER_VARIABLES]})
        {
            $writer->startTag('option');
            $writer->dataElement('name', $option->[0]);
            $writer->dataElement('value', $option->[1]);
            $writer->endTag('option');
        }

        $writer->endTag('commandline_options');
        $writer->endTag('binary');
    }

    $writer->endTag('binaries');
    $writer->endTag('product');
    $writer->end();

    return $buildinfo_xml;
}

1;
