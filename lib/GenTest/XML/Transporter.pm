# Copyright (c) 2008, 2010, Oracle and/or its affiliates. All rights reserved.
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

package GenTest::XML::Transporter;

require Exporter;
@ISA = qw(GenTest);

use strict;
use GenTest;
use GenTest::Constants;

use constant XMLTRANSPORT_MYSQL         => 0;
use constant XMLTRANSPORT_SCP           => 1;
use constant DEFAULT_TRANSPORT_TYPE     => XMLTRANSPORT_SCP;
use constant MYSQL_DEFAULT_DSN          =>
    'dbi:mysql:host=myhost:port=3306:user=xmldrop:password=test;database=test';
use constant SCP_DEFAULT_USER           => 'qauser';
use constant SCP_DEFAULT_HOST           => 'regin.norway.sun.com';
use constant SCP_DEFAULT_DEST_LOCATION  => '/raid/xml_results/TestTool/xml/';
use constant XMLTRANSPORT_TYPES         => {};

1;

#
# Use this class for transporting XML reports to a given destination.
#
# Usage example:
#
#   use GenTest::XML::Transporter;
#   my $xml_transporter = GenTest::XML::Transporter->new();
#   my $result = $xml_transporter->sendXML($xml, undef);
#   if ($result != STATUS_OK) {
#       croak("Error from XML Transporter: $result");
#   }
#
#
sub new {
	my $class = shift;

	my $transporter = $class->SUPER::new({
#		environment	=> XMLREPORT_ENVIRONMENT,
#		date		=> XMLREPORT_DATE,
#		buildinfo	=> XMLREPORT_BUILDINFO,
#		tests		=> XMLREPORT_TESTS
	}, @_);

#	$transporter->[XMLREPORT_DATE] = isoUTCTimestamp() if not defined $transporter->[XMLREPORT_DATE];
#	$transporter->[XMLREPORT_ENVIRONMENT] = GenTest::XML::Environment->new() if not defined  $transporter->[XMLREPORT_ENVIRONMENT];
    $transporter->[XMLTRANSPORT_TYPES] = {
        XMLTRANSPORT_MYSQL         => 0,
        XMLTRANSPORT_SCP           => 1
    };


	return $transporter;
}

#
# Sends XML data to a destination.
# The transport mechanism to use (e.g. file copy, database insert, ftp, etc.)
# and destination is determined by an identifier passed as arg2.
# Valid identifiers are defined as constants in this class.
#
# The default identifier is identified by DEFAULT_TRANSPORT_TYPE.
#
# Arguments:
#   arg1: The xml data (as string).
#   arg2: Identifier of the destination and transport mechamism to be used.
#
sub sendXML {
    my ($self, $xml, $destId) = @_;

    $destId = DEFAULT_TRANSPORT_TYPE if not defined $destId;
    # TODO: Check for valid destId here? ($self->[XMLTRANSPORT_TYPES])

    if ($destId == XMLTRANSPORT_SCP) { return scp(); }
    else {
        say("[ERROR] XML transport id '".$destId."' not supported.");
        return STATUS_ENVIRONMENT_FAILURE;
    }


    
}


sub scp()
{
    say("[ERROR] SCP functionality not implemented yet");
    return STATUS_WONT_HANDLE;

    ## From SysQA. TODO: Adjust to $self:

#  if($^O ne 'cygwin' || $^O ne 'MSWin32' || $^O ne 'MSWin64')
#  {
#    if($scpTest)
#    {
#      system("scp $xml_output $atrUser\@$atrHost:$atrTestPath > /dev/null 2>&1");
#      if ($? != 0){warn "scp to atr_test failed: $? ";}
#    }
#    if($scpPro)
#    {
#      system("scp $xml_output $atrUser\@$atrHost:$atrPath > /dev/null 2>&1");
#      if ($? != 0){warn "scp to atr failed: $?";}
#    }
#  }
#  elsif ($^O eq 'cygwin' || $^O eq 'MSWin32' || $^O eq 'MSWin64')
#  {
#    if($scpTest)
#    {
#      system("pscp.exe -q $xml_output $atrUser\@$atrHost:$atrTestPath");
#      if ($? != 0){warn "pscp to atr_test failed: $? ";}
#    }
#    if($scpPro)
#    {
#      system("pscp.exe -q $xml_output $atrUser\@$atrHost:$atrPath");
#      if ($? != 0){warn "pscp to atr failed: $?";}
#    }
#  }
}