# Copyright (c) 2008, 2011 Oracle and/or its affiliates. All rights reserved.
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

package GenTest::Transform::ExecuteAsView;

require Exporter;
@ISA = qw(GenTest GenTest::Transform);

use strict;
use lib 'lib';

use GenTest;
use GenTest::Transform;
use GenTest::Constants;

my $db_created;


sub transform {
	my ($class, $orig_query, $executor) = @_;
	
	if ($executor->execute("CREATE OR REPLACE VIEW transforms.view_".$$."_probe AS $orig_query", 1)->err() > 0 
		|| $orig_query =~ m{(SYSDATE)\s*\(}sio) 
		|| $orig_query =~ m{(OUTFILE|INFILE)}sio {
		return STATUS_WONT_HANDLE;
	} else {
		$executor->execute("DROP VIEW transforms.view_".$$."_probe");
		return [
			"DROP VIEW IF EXISTS transforms.view_".$$."_merge , transforms.view_".$$."_temptable",
			"CREATE OR REPLACE ALGORITHM=MERGE VIEW transforms.view_".$$."_merge AS $orig_query",
			"SELECT * FROM transforms.view_".$$."_merge /* TRANSFORM_OUTCOME_UNORDERED_MATCH */",
			"CREATE OR REPLACE ALGORITHM=TEMPTABLE VIEW transforms.view_".$$."_temptable AS $orig_query",
			"SELECT * FROM transforms.view_".$$."_temptable /* TRANSFORM_OUTCOME_UNORDERED_MATCH */",
			"DROP VIEW transforms.view_".$$."_merge , transforms.view_".$$."_temptable"
		];
	}
}

1;
