# Copyright (C) 2013 Monty Program Ab
# 
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.


# For a query which has a specific comment of the form
#   Validate <fieldnum starting with 1> <operator: < > = <= >=> <value> for row <rownum starting with 1 or 'all'>
# the validator checks that the given requirement is met,
# i.e. that the value in the field <fieldnum> on the row <rownum> (or on all rows)
# satisfies the given condition <operator> <value>

package GenTest::Validator::CheckFieldValue;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use GenTest;
use GenTest::Comparator;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;

sub validate {
	my ($validator, $executors, $results) = @_;

	my $executor = $executors->[0];
	my $result = $results->[0];
	my $query = $result->query();

	return STATUS_OK if $query !~ m{validate\s+(\d+)\s*([<>=]+)\s*(\w+)\s+for\s+row\s+(\d+|all)}io;
	my ($pos, $sign, $value, $row) = ($1, $2, $3, lc($4));

	my @rownums = ();
	if ( $row eq 'all' ) { 
		foreach ( 0..$#{$result->data()} ) 
		{ 
			push @rownums, $_;
		}
	}
	else {
		@rownums = ( $row - 1 );
	}

	foreach my $r ( @rownums ) 
	{
		my $val = $result->data()->[$r]->[$pos-1];

		if ( ( ( $sign eq '=' or $sign eq '==' ) and not ( $val == $value ) )
			or ( ( $sign eq '<' ) and not ( $val < $value ) ) 
			or ( ( $sign eq '>' ) and not ( $val > $value ) )
			or ( ( $sign eq '<=' ) and not ( $val <= $value ) )
			or ( ( $sign eq '>=' ) and not ( $val >= $value ) ) )
		{
			say("ERROR: For row " . ( $r + 1 ) . " result " . $val . " does not meet the condition $sign $value");
			my $rowset = '';
			foreach my $i ( 0..$#{$result->data()->[$row-1]} ) 
			{
				$rowset .= " [" . ($i + 1 ) . "] : " . $result->data()->[$r]->[$i] . ";";
			}
			say("Full row:$rowset");
			return STATUS_ENVIRONMENT_FAILURE;
		}
	}
	return STATUS_OK;
}

1;
