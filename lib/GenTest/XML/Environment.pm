# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
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

package GenTest::XML::Environment;

require Exporter;
@ISA = qw(GenTest);

use strict;
use GenTest;


sub new {
	my $class = shift;

	my $environment = $class->SUPER::new({
	}, @_);

	return $environment;
}

sub xml {
	require XML::Writer;

	my $environment = shift;
	my $environment_xml;

	my $writer = XML::Writer->new(
		OUTPUT		=> \$environment_xml,
	);

	$writer->startTag('environments');
	$writer->startTag('environment', 'id' => 0);
	$writer->startTag('hosts');
	$writer->startTag('host');

	$writer->dataElement('name', `hostname`);
	$writer->dataElement('arch', $^O);
	$writer->dataElement('role', 'server');

	# <os>

	# <software>

	$writer->startTag('software');
	$writer->startTag('program');
	$writer->dataElement('name', 'perl');
	$writer->dataElement('version', $^V);
	$writer->dataElement('path', $^X);
	$writer->endTag('program');
	$writer->endTag('software');

	$writer->endTag('host');
	$writer->endTag('hosts');
	$writer->endTag('environment');
	$writer->endTag('environments');

	$writer->end();

	return $environment_xml;	
}

1;
