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
#

package GenTest::SimPipe::Testcase;

require Exporter;
@ISA = qw(GenTest);
@EXPORT = qw(
	
);

use strict;

use GenTest;
use GenTest::Constants;

use constant TESTCASE_MYSQLD_OPTIONS	=> 0;
use constant TESTCASE_DB_OBJECTS	=> 1;
use constant TESTCASE_QUERIES		=> 2;

use constant MYSQLD_OPTION_NAME		=> 0;
use constant MYSQLD_OPTION_VALUE	=> 1;

1;

sub new {
	my $class = shift;

	my $testcase = $class->SUPER::new({
		'mysqld_options'	=> TESTCASE_MYSQLD_OPTIONS,
		'db_objects'		=> TESTCASE_DB_OBJECTS,
		'queries'		=> TESTCASE_QUERIES,
	}, @_);
	
	return $testcase;
}

sub mysqldOptions {
	return $_[0]->[TESTCASE_MYSQLD_OPTIONS];
}

sub dbObjects {
	return $_[0]->[TESTCASE_DB_OBJECTS];
}

sub queries {
	return $_[0]->[TESTCASE_QUERIES];
}

sub mysqldOptionsToString {
	my $testcase = shift;
	
	my @mysqld_option_strings;

	while (my ($option_name, $option_value) = each %{$testcase->mysqldOptions()}) {
		next if not defined $option_value;
		if ($option_value =~ m{^\d*$}sio) {
			push @mysqld_option_strings, "SET SESSION $option_name = $option_value;";
		} else {
			push @mysqld_option_strings, "SET SESSION $option_name = '$option_value';";
		}
	}

	return join("\n", @mysqld_option_strings);
}

sub dbObjectsToString {
	my $testcase = shift;

	my @dbobject_strings;

	foreach my $dbobject (@{$testcase->dbObjects()}) {
		next if not defined $dbobject;
		push @dbobject_strings, $dbobject->toString();
	}

	return join("\n", @dbobject_strings);
}

sub toString {
	my $testcase = shift;
	return $testcase->mysqldOptionsToString()."\n".$testcase->dbObjectsToString()."\n".join("\n", @{$testcase->queries()})."\n";
}	
