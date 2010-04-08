# Copyright (c) 2008, 2010 Oracle and/or its affiliates. All rights reserved.
# Use is subject to license terms.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301
# USA

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

        # TODO: Add support for non-MySQL dsns.
        $server->[BUILDINFO_SERVER_VERSION] = $dbh->selectrow_array('SELECT @@version');
        $server->[BUILDINFO_SERVER_PACKAGE] = $dbh->selectrow_array('SELECT @@version_comment');
        # According to the schema, bit must be "32" or "64".
        #$server->[BUILDINFO_SERVER_BIT] = $dbh->selectrow_array('SELECT @@version_compile_machine');
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
    $writer->dataElement('name','MySQL');
    $writer->startTag('builds');

    foreach my $id (0..$#{$buildinfo->[BUILDINFO_DSNS]})
    {
        my $server = $buildinfo->[BUILDINFO_SERVERS]->[$id];
        next if not defined $server;

        $writer->startTag('build', id => $id);
        $writer->dataElement('version', $server->[BUILDINFO_SERVER_VERSION]);
        $writer->dataElement('package', $server->[BUILDINFO_SERVER_PACKAGE]);
        #$writer->dataElement('bit', $server->[BUILDINFO_SERVER_BIT]); # Must be 32 or 64
        $writer->dataElement('path', $server->[BUILDINFO_SERVER_PATH]);
        ## TODO (if applicable):
        #<xsd:element name="tree" type="xsd:string" minOccurs="0" form="qualified"/>
        #<xsd:element name="revision" type="xsd:string" minOccurs="0" form="qualified"/>
        #<xsd:element name="tag" type="xsd:string" minOccurs="0" form="qualified"/>
        #<xsd:element name="compile_options" type="cassiopeia:Options" minOccurs="0" form="qualified"/>
        #<xsd:element name="commandline" type="xsd:string" minOccurs="0" form="qualified" />
        #<xsd:element name="buildscript" minOccurs="0" type="xsd:string" form="qualified" />
        $writer->endTag('build');
    }


    $writer->endTag('builds');

    $writer->startTag('binaries'); # --> <software> = <program>

    foreach my $id (0..$#{$buildinfo->[BUILDINFO_DSNS]})
    {
        my $server = $buildinfo->[BUILDINFO_SERVERS]->[$id];
        next if not defined $server;

        $writer->startTag('program');
        $writer->dataElement('name', 'mysqld');
        $writer->dataElement('type', 'database');
        $writer->startTag('commandline_options');

    # TODO: List actual commmand-line options (and config file options /
    #       RQG-defaults?), not all server variables?
        foreach my $option (@{$server->[BUILDINFO_SERVER_VARIABLES]})
        {
            $writer->startTag('option');
            $writer->dataElement('name', $option->[0]);
            $writer->dataElement('value', $option->[1]);
            $writer->endTag('option');
        }

        $writer->endTag('commandline_options');
        $writer->endTag('program');
    }

    $writer->endTag('binaries');
    $writer->endTag('product');
    $writer->end();

    return $buildinfo_xml;
}

1;
